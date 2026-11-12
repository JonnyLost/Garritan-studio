import Foundation
import Dispatch

/// Cross-layer matrix driver. The worker runs only when at least one route is
/// enabled, at 50 Hz with generous scheduler leeway for MacBook battery life.
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
    private var baselines: [Key: Float] = [:]
    private var clock: DispatchSourceTimer?
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

    init(settings: StudioSynthModulationSettings, tempo: Double = 120,
         read: @escaping (UUID, StudioSynthModDestination) -> Float?,
         write: @escaping (UUID, StudioSynthModDestination, Float) -> Bool) {
        self.settings = settings
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

    /// Queue-confined tempo changes preserve integrated beat position instead
    /// of restarting or rephasing synced LFOs. Not called by audio render code.
    func setTempo(_ bpm: Double) {
        guard bpm.isFinite && bpm > 0 else { return }
        queue.async { [weak self] in
            self?.tempo = bpm
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
                applyCurrentValues()
                return true
            }
            return write(layer, destination, value)
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

    private func activeKeys() -> Set<Key> {
        Set(settings.routes.filter(\.enabled).map {
            Key(layer: $0.layerID, destination: $0.destination)
        })
    }

    private func install(_ newer: StudioSynthModulationSettings,
                         restoringOldRoutes: Bool) {
        let previous = activeKeys()
        settings = newer
        let next = activeKeys()

        if restoringOldRoutes {
            for key in previous.subtracting(next) {
                if let value = baselines[key] {
                    _ = write(key.layer, key.destination, value)
                }
            }
        }

        for key in next {
            if baselines[key] == nil {
                baselines[key] = read(key.layer, key.destination)
                    ?? key.destination.defaultValue
            }
        }

        if newer.hasEnabledRoutes {
            if clock == nil {
                lastUptime = nil
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: .milliseconds(20),
                                leeway: .milliseconds(5))
                source.setEventHandler { [weak self] in
                    self?.tick()
                }
                clock = source
                source.resume()
            }
        } else {
            clock?.cancel()
            clock = nil
            lastUptime = nil
        }
        applyCurrentValues()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous = lastUptime, now >= previous {
            let delta = min(0.15, Double(now - previous) / 1_000_000_000)
            elapsed += delta
            elapsedBeats += delta * tempo / 60
            _ = envelope.advance(seconds: delta, settings: settings)
        }
        lastUptime = now
        applyCurrentValues()
    }

    private func applyCurrentValues() {
        guard settings.hasEnabledRoutes else { return }

        // Accumulate all sources targeting the same parameter before writing
        // exactly once. No per-route last-writer-wins overwrite, and every
        // result is clamped within that engine's valid parameter range.
        var offsets: [Key: Float] = [:]
        for route in settings.routes where route.enabled {
            let key = Key(layer: route.layerID, destination: route.destination)
            let signal = StudioSynthModulationMath.signal(
                route.source, seconds: elapsed, settings: settings,
                envelope: envelope.value, wheel: wheel,
                bpm: tempo, beats: elapsedBeats)
            offsets[key, default: 0] += route.depth * signal
        }
        for (key, amount) in offsets {
            let base = baselines[key] ?? key.destination.defaultValue
            let effective = key.destination.apply(base: base, normalizedOffset: amount)
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
