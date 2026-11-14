import Foundation
import Dispatch

/// Cross-layer matrix driver. The worker runs only when at least one route is
/// enabled, normally at 50 Hz. Short sync divisions dynamically raise the
/// control rate for fidelity; idle or slow patches keep low battery cost.
/// All DSP destinations are existing C++ atomic parameter setters. This class
/// is NEVER called from an AVAudioSourceNode render callback.
///
/// Cross-layer sources are control-rate, not per-voice/sample-accurate. Global
/// ADSR follows the combined MIDI key/sustain gate. CC1 is the last incoming
/// CC1 value (one macro control shared across all MIDI channels).
internal final class StudioSynthModulationWorker {
    private struct Key: Hashable {
        let layer: UUID
        let destination: StudioSynthModDestination
    }

    private let queue = DispatchQueue(label: "com.garritan.studio-synth.modulation",
                                      qos: .utility)
    private let read: (UUID, StudioSynthModDestination) -> Float?
    private let write: (UUID, StudioSynthModDestination, Float) -> Bool

    // All mutable fields below are owned exclusively by queue.
    private var settings: StudioSynthModulationSettings
    private var controls: StudioSynthMIDIControlSettings
    private var baselines: [Key: Float] = [:]
    // MIDI CC changes a performance value rather than the saved patch's
    // original knob setting. Removing a mapping restores that original base.
    private var controllerBases: [Key: Float] = [:]
    // Transport changes a temporary base rather than saved preset values.
    private var automationBases: [Key: Float] = [:]
    private var macroOverride: Float?
    private var clock: DispatchSourceTimer?
    private var clockIntervalUs: Int?
    private var elapsed = 0.0
    /// Integrated beats retain phase across BPM changes, including while held.
    private var elapsedBeats = 0.0
    private var tempo: Double
    private var lastUptime: UInt64?
    private var envelope = StudioSynthModulationEnvelope()
    private var wheel: Float = 0
    private var pressed = [Bool](repeating: false, count: 16 * 128)
    private var sustained = [Bool](repeating: false, count: 16 * 128)
    private var pedal = [Bool](repeating: false, count: 16)

    init(settings: StudioSynthModulationSettings,
         midiControls: StudioSynthMIDIControlSettings = StudioSynthMIDIControlSettings(),
         tempo: Double = 120,
         read: @escaping (UUID, StudioSynthModDestination) -> Float?,
         write: @escaping (UUID, StudioSynthModDestination, Float) -> Bool) {
        self.settings = settings
        self.controls = midiControls
        self.tempo = tempo.isFinite && tempo > 0 ? tempo : 120
        self.read = read
        self.write = write
        queue.sync {
            self.install(settings, restoringOldRoutes: false)
        }
    }

    deinit {
        // The timer callback captures self weakly. Cancellation does not wait
        // for its event handler, and remains safe if teardown occurs there.
        clock?.cancel()
    }

    func update(_ settings: StudioSynthModulationSettings) {
        queue.sync { self.install(settings, restoringOldRoutes: true) }
    }

    /// Controller assignments update without destroying the sound graph or
    /// restarting notes. The same queue owns CC values and modulation bases.
    func updateMIDIControls(_ newer: StudioSynthMIDIControlSettings) {
        queue.sync {
            let oldKeys = self.activeKeys()
            let oldMapped = self.mappedKeys()
            self.controls = newer
            self.reconcile(previous: oldKeys, oldMapped: oldMapped,
                           restoringOldRoutes: true)
        }
    }

    /// Queue-confined tempo changes preserve integrated beat position instead
    /// of restarting or rephasing synced LFOs. Not called by audio render code.
    func setTempo(_ bpm: Double) {
        guard bpm.isFinite && bpm > 0 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Account for time at the OLD tempo first; never retroactively
            // rephase the beat clock when the user changes BPM.
            self.advanceClock()
            self.tempo = bpm
            self.scheduleClockIfNeeded()
            self.applyCurrentValues()
        }
    }

    /// A user edit changes the unmodulated base, never the temporary swept
    /// value. All writes for a routed parameter are serialized on this worker.
    func setBase(layer: UUID, destination: StudioSynthModDestination,
                 value: Float) -> Bool {
        queue.sync {
            let key = Key(layer: layer, destination: destination)
            if activeKeys().contains(key) {
                baselines[key] = value
                // An explicit manual knob change takes precedence until the
                // next incoming mapped MIDI CC.
                controllerBases.removeValue(forKey: key)
                applyCurrentValues()
                return true
            }
            return write(layer, destination, value)
        }
    }

    /// Apply transport values on this worker, never in the audio callback.
    /// A stopped transport releases every automation value and restores the
    /// saved base even if a controller had previously moved it.
    func setAutomation(layer: UUID, destination: StudioSynthModDestination,
                       normalized: Float) -> Bool {
        guard normalized.isFinite, (0...1).contains(normalized),
              destination.isContinuouslyModulatable else { return false }
        return queue.sync {
            let key = Key(layer: layer, destination: destination)
            let previous = activeKeys()
            automationBases[key] = destination.value(at: Double(normalized))
            reconcile(previous: previous, oldMapped: mappedKeys(),
                      restoringOldRoutes: true)
            return true
        }
    }

    func clearAutomation() {
        queue.sync {
            let previous = activeKeys()
            automationBases.removeAll()
            reconcile(previous: previous, oldMapped: mappedKeys(),
                      restoringOldRoutes: true)
        }
    }

    /// The host's existing MIDI producers feed a copy of *accepted* events.
    /// This does not alter MIDI timing or block the render thread.
    func receiveMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let group = status & 0xF0
        guard group == 0x90 || group == 0x80 || group == 0xB0 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.handleMIDI(group: group, channel: Int(status & 0x0F),
                            data1: data1, data2: data2)
            self.applyCurrentValues()
        }
    }

    func panic() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pressed = [Bool](repeating: false, count: 16 * 128)
            self.sustained = [Bool](repeating: false, count: 16 * 128)
            self.pedal = [Bool](repeating: false, count: 16)
            self.envelope.reset()
            self.wheel = 0
            self.applyCurrentValues()
        }
    }

    private func mappedKeys() -> Set<Key> {
        Set(controls.mappings.compactMap { mapping -> Key? in
            guard mapping.enabled,
                  case .parameter(let id, let destination) = mapping.target else {
                return nil
            }
            return Key(layer: id, destination: destination)
        })
    }

    private func activeKeys() -> Set<Key> {
        let modulated = Set(settings.routes.filter(\.enabled).map {
            Key(layer: $0.layerID, destination: $0.destination)
        })
        return modulated.union(mappedKeys()).union(automationBases.keys)
    }

    private func install(_ newer: StudioSynthModulationSettings,
                         restoringOldRoutes: Bool) {
        let previous = activeKeys()
        let oldMapped = mappedKeys()
        settings = newer
        reconcile(previous: previous, oldMapped: oldMapped,
                  restoringOldRoutes: restoringOldRoutes)
    }

    private func reconcile(previous: Set<Key>, oldMapped: Set<Key>,
                           restoringOldRoutes: Bool) {
        let next = activeKeys()
        for key in oldMapped.subtracting(mappedKeys()) {
            controllerBases.removeValue(forKey: key)
        }
        if !controls.mappings.contains(where: {
            $0.enabled && $0.target == .macro1
        }) {
            macroOverride = nil
        }
        if restoringOldRoutes {
            for key in previous.subtracting(next) {
                if let value = baselines[key] {
                    _ = write(key.layer, key.destination, value)
                }
                baselines.removeValue(forKey: key)
                controllerBases.removeValue(forKey: key)
            }
        }
        for key in next where baselines[key] == nil {
            baselines[key] = read(key.layer, key.destination)
                ?? key.destination.defaultValue
        }

        if settings.hasEnabledRoutes {
            scheduleClockIfNeeded()
        } else {
            clock?.cancel()
            clock = nil
            clockIntervalUs = nil
            lastUptime = nil
        }
        applyCurrentValues()
    }

    private func scheduleClockIfNeeded() {
        guard settings.hasEnabledRoutes else { return }
        let hz = StudioSynthModulationMath.controlRate(settings, bpm: tempo)
        // Microsecond scheduling avoids rounding a 400Hz target up to 500Hz
        // and permits accurate intermediate note-division rates.
        let interval = max(2_500, Int((1_000_000 / hz).rounded(.up)))
        guard clock == nil || clockIntervalUs != interval else { return }
        let leeway = max(500, min(5_000, interval / 4))
        if let clock {
            clock.schedule(deadline: .now(), repeating: .microseconds(interval),
                           leeway: .microseconds(leeway))
        } else {
            lastUptime = nil
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .microseconds(interval),
                            leeway: .microseconds(leeway))
            source.setEventHandler { [weak self] in
                self?.tick()
            }
            clock = source
            source.resume()
        }
        clockIntervalUs = interval
    }

    private func advanceClock() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous = lastUptime, now >= previous {
            let elapsedSeconds = Double(now - previous) / 1_000_000_000
            // Preserve LFO phase across a stalled timer, but continue
            // capping envelope steps to avoid skipping its entire attack.
            elapsed += elapsedSeconds
            elapsedBeats += elapsedSeconds * tempo / 60
            _ = envelope.advance(seconds: min(0.15, elapsedSeconds),
                                 settings: settings)
        }
        lastUptime = now
    }

    private func tick() {
        advanceClock()
        applyCurrentValues()
    }

    private func applyCurrentValues() {
        guard settings.hasEnabledRoutes || controls.hasEnabledMappings ||
              !automationBases.isEmpty else {
            return
        }

        // A CC-controlled macro supplies the modulation matrix's Macro 1
        // source without modifying the persisted Macro 1 knob value.
        var effectiveSettings = settings
        if let macroOverride { effectiveSettings.macro1 = macroOverride }
        var offsets: [Key: Float] = [:]
        for route in settings.routes where route.enabled {
            let key = Key(layer: route.layerID, destination: route.destination)
            let signal = StudioSynthModulationMath.signal(
                route.source, seconds: elapsed, settings: effectiveSettings,
                envelope: envelope.value, wheel: wheel,
                bpm: tempo, beats: elapsedBeats)
            offsets[key, default: 0] += route.depth * signal
        }
        // Sum modulation after the MIDI-controlled base value. A single CC
        // can drive several layer parameters, with no "last writer wins" race.
        for key in activeKeys() {
            let base = automationBases[key] ?? controllerBases[key] ?? baselines[key]
                ?? key.destination.defaultValue
            let effective = key.destination.apply(
                base: base, normalizedOffset: offsets[key] ?? 0)
            _ = write(key.layer, key.destination, effective)
        }
    }

    private func handleMIDI(group: UInt8, channel: Int,
                            data1: UInt8, data2: UInt8) {
        let index = channel * 128 + Int(data1)
        if group == 0x90 && data2 > 0 {
            pressed[index] = true
            sustained[index] = false
            envelope.trigger()
        } else if group == 0x80 || group == 0x90 {
            pressed[index] = false
            sustained[index] = pedal[channel]
            releaseIfNoNotes()
        } else if group == 0xB0 {
            // MIDI Learn is evaluated on the existing control worker and
            // never from an AVAudioSourceNode render callback.
            for mapping in controls.mappings where
                mapping.matches(controller: data1, channel: UInt8(channel)) {
                guard let position = mapping.position(for: data2) else { continue }
                switch mapping.target {
                case .macro1:
                    macroOverride = position
                case .parameter(let id, let destination):
                    controllerBases[Key(layer: id, destination: destination)] =
                        destination.value(at: Double(position))
                }
            }
            switch data1 {
            case 1:
                wheel = Float(data2) / 127
            case 64:
                pedal[channel] = data2 >= 64
                if !pedal[channel] {
                    for note in 0..<128 {
                        sustained[channel * 128 + note] = false
                    }
                    releaseIfNoNotes()
                }
            case 120, 123:
                for note in 0..<128 {
                    pressed[channel * 128 + note] = false
                    sustained[channel * 128 + note] = false
                }
                pedal[channel] = false
                releaseIfNoNotes()
            default: break
            }
        }
    }

    private func releaseIfNoNotes() {
        if !pressed.contains(true) && !sustained.contains(true) {
            envelope.release()
        }
    }
}
