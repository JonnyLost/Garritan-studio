import Foundation
import AVFoundation
import AudioToolbox

public enum StudioSynthError: Error, LocalizedError {
    case invalidPatch
    case invalidConfiguration
    case unsupportedAudioBackend

    public var errorDescription: String? {
        switch self {
        case .invalidPatch: return "Studio Synth has an invalid layer or sound patch."
        case .invalidConfiguration: return "Studio Synth could not create its native audio graph."
        case .unsupportedAudioBackend:
            return "Studio Synth currently requires Studio's AVAudioEngine backend."
        }
    }
}

/// Each active layer owns its source renderer and a lightweight AVAudioMixerNode
/// for independent level and pan. All graph mutations happen with the render
/// stopped; no allocations or locks are introduced inside DSP callbacks.
private final class StudioSynthRuntimeLayer {
    let id: UUID
    let mixer = AVAudioMixerNode()
    let analog: StudioAnalogInstrument?
    let fm: StudioFMInstrument?
    let wavetable: StudioWavetableInstrument?
    let additive: StudioAdditiveInstrument?
    let granular: StudioGranularInstrument?
    let physical: StudioPhysicalInstrument?

    var source: AVAudioNode {
        if let analog { return analog.audioNode }
        if let fm { return fm.audioNode }
        if let wavetable { return wavetable.audioNode }
        if let additive { return additive.audioNode }
        if let granular { return granular.audioNode }
        return physical!.audioNode
    }
    var format: AVAudioFormat {
        if let analog { return analog.format }
        if let fm { return fm.format }
        if let wavetable { return wavetable.format }
        if let additive { return additive.format }
        if let granular { return granular.format }
        return physical!.format
    }

    init(_ layer: StudioSynthLayer, sampleRate: Double) throws {
        id = layer.id
        switch layer.engine {
        case .analog:
            let synth = try StudioAnalogInstrument(sampleRate: sampleRate)
            let patch = layer.analogPatch ?? StudioAnalogPatch()
            synth.apply(patch)
            if patch.connections != nil {
                try synth.setRouting(patch.activeConnections)
            }
            analog = synth
            fm = nil
            wavetable = nil
            additive = nil
            granular = nil
            physical = nil
        case .fm:
            let synth = try StudioFMInstrument(sampleRate: sampleRate)
            try synth.apply(layer.fmPatch ?? StudioFMPatch())
            analog = nil
            fm = synth
            wavetable = nil
            additive = nil
            granular = nil
            physical = nil
        case .wavetable:
            let synth = try StudioWavetableInstrument(sampleRate: sampleRate)
            try synth.apply(layer.wavetablePatch ?? StudioWavetablePatch())
            analog = nil
            fm = nil
            wavetable = synth
            additive = nil
            granular = nil
            physical = nil
        case .additive:
            let synth = try StudioAdditiveInstrument(sampleRate: sampleRate)
            try synth.apply(layer.additivePatch ?? StudioAdditivePatch())
            analog = nil
            fm = nil
            wavetable = nil
            additive = synth
            granular = nil
            physical = nil
        case .granular:
            let synth = try StudioGranularInstrument(
                sampleRate: sampleRate,
                patch: layer.granularPatch ?? StudioGranularPatch())
            analog = nil
            fm = nil
            wavetable = nil
            additive = nil
            granular = synth
            physical = nil
        case .physical:
            let synth = try StudioPhysicalInstrument(
                sampleRate: sampleRate,
                patch: layer.physicalPatch ?? StudioPhysicalPatch())
            analog = nil
            fm = nil
            wavetable = nil
            additive = nil
            granular = nil
            physical = synth
        }
        mixer.outputVolume = layer.gain
        mixer.pan = layer.pan
    }

    func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                     frameOffset: UInt32) -> Bool {
        if let analog {
            return analog.midiMessage(status: status, data1: data1,
                                      data2: data2, frameOffset: frameOffset)
        }
        if let fm {
            return fm.midiMessage(status: status, data1: data1,
                                  data2: data2, frameOffset: frameOffset)
        }
        if let wavetable {
            return wavetable.midiMessage(status: status, data1: data1,
                                         data2: data2, frameOffset: frameOffset)
        }
        if let additive {
            return additive.midiMessage(status: status, data1: data1,
                                        data2: data2, frameOffset: frameOffset)
        }
        if let granular {
            return granular.midiMessage(status: status, data1: data1,
                                        data2: data2, frameOffset: frameOffset)
        }
        return physical!.midiMessage(status: status, data1: data1,
                                     data2: data2, frameOffset: frameOffset)
    }

    func allNotesOff() -> Bool {
        if let analog { return analog.allNotesOff() }
        if let fm { return fm.allNotesOff() }
        if let wavetable { return wavetable.allNotesOff() }
        if let additive { return additive.allNotesOff() }
        if let granular { return granular.allNotesOff() }
        return physical!.allNotesOff()
    }
}

/// Unified native synthesizer container. This is an audio-graph composition
/// of the existing *independent* Analog and FM engines, not a replacement for
/// their proven C++ renderers or a third-party plug-in host.
///
/// Host MIDI reaches each active engine's lock-free queue through its existing
/// producer guard. Inactive layers allocate no voice engine or audio nodes.
/// The parent mixer is connected to Studio's normal per-track input path,
/// preserving faders, metering, panning and Concert Hall sends.
public final class StudioSynthInstrument {
    public let audioNode = AVAudioMixerNode()
    public let patch: StudioSynthPatch
    private let runtime: [StudioSynthRuntimeLayer]
    private var modulationWorker: StudioSynthModulationWorker?
    // MIDI producers and the SwiftUI editor may run on different queues.
    // Protect the worker reference, never the AVAudioSourceNode callback.
    private let workerReferenceLock = NSLock()
    // Snapshot for MIDI producer threads; never accessed by audio callbacks.
    private var activeCCMappings: [StudioSynthMIDIControlMapping] = []
    private var currentModulation: StudioSynthModulationSettings
    private var currentMIDIControls: StudioSynthMIDIControlSettings
    private var automationActive = false
    private var tempo: Double

    public init(sampleRate: Double, patch: StudioSynthPatch,
                tempo: Double = 120) throws {
        guard patch.validate() else { throw StudioSynthError.invalidPatch }
        self.patch = patch
        self.tempo = tempo.isFinite && tempo > 0 ? tempo : 120
        currentModulation = patch.modulation ?? StudioSynthModulationSettings()
        currentMIDIControls = patch.midiControls ?? StudioSynthMIDIControlSettings()
        runtime = try patch.layers.filter(\.enabled).map {
            try StudioSynthRuntimeLayer($0, sampleRate: sampleRate)
        }
        if currentModulation.hasEnabledRoutes || currentMIDIControls.hasEnabledMappings {
            createControlWorker()
        }
    }

    private func controlWorker() -> StudioSynthModulationWorker? {
        workerReferenceLock.lock()
        defer { workerReferenceLock.unlock() }
        return modulationWorker
    }

    private func createControlWorker() {
        let worker = StudioSynthModulationWorker(
            settings: currentModulation, midiControls: currentMIDIControls,
            tempo: tempo,
            read: { [weak self] id, destination in
                self?.directParameter(id: id, destination: destination)
            },
            write: { [weak self] id, destination, value in
                self?.writeParameter(id: id, destination: destination, value: value)
                    ?? false
            })
        workerReferenceLock.lock()
        modulationWorker = worker
        activeCCMappings = currentMIDIControls.mappings.filter(\.enabled)
        workerReferenceLock.unlock()
    }

    private func refreshControlWorker() {
        let needed = currentModulation.hasEnabledRoutes ||
            currentMIDIControls.hasEnabledMappings || automationActive
        if let worker = controlWorker() {
            worker.update(currentModulation)
            worker.updateMIDIControls(currentMIDIControls)
            if !needed {
                workerReferenceLock.lock()
                modulationWorker = nil
                activeCCMappings.removeAll()
                workerReferenceLock.unlock()
            }
        } else if needed {
            createControlWorker()
        }
    }

    private func directParameter(id: UUID,
                                 destination: StudioSynthModDestination) -> Float? {
        guard let layer = runtime.first(where: { $0.id == id }) else { return nil }
        switch destination {
        case .analog(let param):
            return layer.analog?.parameter(param.rawValue)
        case .fm(let param):
            return layer.fm?.parameter(param)
        case .wavetable(let param):
            return layer.wavetable?.parameter(param)
        case .additive(let param):
            return layer.additive?.parameter(param)
        case .granular(let param):
            return layer.granular?.parameter(param)
        case .physical(let param):
            return layer.physical?.parameter(param)
        }
    }

    private func writeParameter(id: UUID, destination: StudioSynthModDestination,
                                value: Float) -> Bool {
        guard let layer = runtime.first(where: { $0.id == id }),
              destination.valid(value) else { return false }
        switch destination {
        case .analog(let param):
            return layer.analog?.setParameter(param.rawValue, value: value) ?? false
        case .fm(let param):
            return layer.fm?.setParameter(param, value: value) ?? false
        case .wavetable(let param):
            return layer.wavetable?.setParameter(param, value: value) ?? false
        case .additive(let param):
            return layer.additive?.setParameter(param, value: value) ?? false
        case .granular(let param):
            return layer.granular?.setParameter(param, value: value) ?? false
        case .physical(let param):
            return layer.physical?.setParameter(param, value: value) ?? false
        }
    }

    /// Live cross-layer routing does not rebuild the audio graph, stop playback
    /// or reset voices. A 50Hz worker is active only while routes are enabled.
    @discardableResult
    public func setModulation(_ settings: StudioSynthModulationSettings) -> Bool {
        guard settings.validate(layers: patch.layers) else { return false }
        currentModulation = settings
        refreshControlWorker()
        return true
    }

    /// Install controller mappings in place, without rebuilding the audio
    /// graph or mutating the original, saved sound parameter defaults.
    @discardableResult
    public func setMIDIControls(_ controls: StudioSynthMIDIControlSettings) -> Bool {
        guard controls.validate(layers: patch.layers) else { return false }
        currentMIDIControls = controls
        refreshControlWorker()
        workerReferenceLock.lock()
        activeCCMappings = controls.mappings.filter(\.enabled)
        workerReferenceLock.unlock()
        return true
    }

    /// Apply a normalized automation value at control rate, without editing
    /// the persistent StudioSynthPatch or creating an audio-thread lock.
    /// Automation overrides a mapped CC while active. Modulation continues
    /// to add its offset to that temporary automation base.
    @discardableResult
    public func setAutomation(layerID: UUID,
                              destination: StudioSynthModDestination,
                              normalized: Float) -> Bool {
        guard destination.engine == runtime.first(where: {
            $0.id == layerID
        })?.engine,
              destination.isContinuouslyModulatable,
              normalized.isFinite, (0...1).contains(normalized) else {
            return false
        }
        if controlWorker() == nil { createControlWorker() }
        let accepted = controlWorker()?.setAutomation(
            layer: layerID, destination: destination,
            normalized: normalized) ?? false
        if accepted { automationActive = true }
        return accepted
    }

    /// Restore saved and controller baselines on Stop or when lanes are
    /// disabled, while leaving the currently sounding voices intact.
    public func clearAutomation() {
        controlWorker()?.clearAutomation()
        automationActive = false
        refreshControlWorker()
    }

    /// A live host tempo edit affects both synced LFOs without resetting phase
    /// or rebuilding the AVAudioEngine graph. Free-running Hz stays unchanged.
    public func setTempo(_ bpm: Double) {
        guard bpm.isFinite && bpm > 0 else { return }
        tempo = bpm
        controlWorker()?.setTempo(bpm)
    }

    /// Useful for both UI meters and regression tests: reads the engine's
    /// *current effective* parameter, including any matrix modulation.
    public func effectiveParameter(id: UUID,
                                   destination: StudioSynthModDestination) -> Float? {
        directParameter(id: id, destination: destination)
    }

    /// Called only from PlaybackEngine while the AVAudioEngine is stopped.
    public func attach(to engine: AVAudioEngine, destination: AVAudioNode,
                       sampleRate: Double) throws {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 2) else {
            throw StudioSynthError.invalidConfiguration
        }
        engine.attach(audioNode)
        for layer in runtime {
            engine.attach(layer.source)
            engine.attach(layer.mixer)
            engine.connect(layer.source, to: layer.mixer, format: layer.format)
            engine.connect(layer.mixer, to: audioNode, format: stereo)
        }
        engine.connect(audioNode, to: destination, format: stereo)
    }

    /// Graph teardown order is delegated to PlaybackEngine, with rendering
    /// stopped. The root mixer is detached by the existing removal path.
    public var auxiliaryNodes: [AVAudioNode] {
        runtime.flatMap { [$0.source, $0.mixer] }
    }

    @discardableResult
    public func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        var accepted = true
        // Do not short-circuit. Even if one queue is full, all others
        // must receive their note-off or controller event.
        for layer in runtime {
            if !layer.midiMessage(status: status, data1: data1,
                                  data2: data2, frameOffset: frameOffset) {
                accepted = false
            }
        }
        // The matrix receives a copy on its own low-priority control worker.
        // No modulation calculations or locks are added to render callbacks.
        controlWorker()?.receiveMIDI(status: status, data1: data1, data2: data2)
        // Native DSPs correctly reject otherwise unsupported controllers
        // such as CC74. MIDI Learn handles those on its control-rate worker,
        // so the container reports an accepted mapped CC while preserving
        // rejection semantics for unsupported messages and note events.
        guard (status & 0xF0) == 0xB0 else { return accepted }
        workerReferenceLock.lock()
        let mapped = activeCCMappings.contains {
            $0.matches(controller: data1, channel: status & 0x0F)
        }
        workerReferenceLock.unlock()
        return accepted || mapped
    }

    @discardableResult
    public func noteOn(_ note: UInt8, velocity: UInt8, channel: UInt8 = 0,
                       frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0x90 | (channel & 0x0F), data1: note,
                    data2: velocity, frameOffset: frameOffset)
    }

    @discardableResult
    public func noteOff(_ note: UInt8, channel: UInt8 = 0,
                        frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0x80 | (channel & 0x0F), data1: note,
                    data2: 0, frameOffset: frameOffset)
    }

    @discardableResult
    public func controller(_ number: UInt8, value: UInt8, channel: UInt8 = 0,
                           frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0xB0 | (channel & 0x0F), data1: number,
                    data2: value, frameOffset: frameOffset)
    }

    @discardableResult
    public func pitchBend(_ value: UInt16, channel: UInt8 = 0,
                          frameOffset: UInt32 = 0) -> Bool {
        guard value <= 16_383 else { return false }
        return midiMessage(status: 0xE0 | (channel & 0x0F),
                           data1: UInt8(value & 0x7F),
                           data2: UInt8((value >> 7) & 0x7F),
                           frameOffset: frameOffset)
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        var accepted = true
        for layer in runtime {
            if !layer.allNotesOff() { accepted = false }
        }
        controlWorker()?.panic()
        return accepted
    }

    public func setMix(id: UUID, gain: Float, pan: Float) -> Bool {
        guard gain.isFinite, (0...1).contains(gain),
              pan.isFinite, (-1...1).contains(pan),
              let layer = runtime.first(where: { $0.id == id }) else { return false }
        layer.mixer.outputVolume = gain
        layer.mixer.pan = pan
        return true
    }

    public func setAnalogParameter(id: UUID, parameter: StudioAnalogParameter,
                                   value: Float) -> Bool {
        guard parameter.valid(value),
              runtime.first(where: { $0.id == id })?.analog != nil else {
            return false
        }
        let destination = StudioSynthModDestination.analog(parameter)
        return controlWorker()?.setBase(layer: id, destination: destination,
                                          value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }

    public func setWavetableParameter(id: UUID, parameter: StudioWavetableParameter,
                                      value: Float) -> Bool {
        guard parameter.valid(value),
              runtime.first(where: { $0.id == id })?.wavetable != nil else {
            return false
        }
        let destination = StudioSynthModDestination.wavetable(parameter)
        return controlWorker()?.setBase(layer: id, destination: destination,
                                          value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }

    public func setAdditiveParameter(id: UUID, parameter: StudioAdditiveParameter,
                                     value: Float) -> Bool {
        guard parameter.valid(value),
              runtime.first(where: { $0.id == id })?.additive != nil else {
            return false
        }
        let destination = StudioSynthModDestination.additive(parameter)
        return controlWorker()?.setBase(layer: id, destination: destination,
                                        value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }

    public func setGranularParameter(id: UUID, parameter: StudioGranularParameter,
                                     value: Float) -> Bool {
        guard parameter.valid(value),
              runtime.first(where: { $0.id == id })?.granular != nil else {
            return false
        }
        let destination = StudioSynthModDestination.granular(parameter)
        return controlWorker()?.setBase(layer: id, destination: destination,
                                        value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }

    public func setPhysicalParameter(id: UUID, parameter: StudioPhysicalParameter,
                                     value: Float) -> Bool {
        guard parameter.valid(value),
              runtime.first(where: { $0.id == id })?.physical != nil else {
            return false
        }
        // Discrete model changes remain atomic; cross-layer modulation
        // only exposes continuously variable physical parameters.
        let destination = StudioSynthModDestination.physical(parameter)
        return controlWorker()?.setBase(layer: id, destination: destination,
                                          value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }

    public func setFMParameter(id: UUID, parameter: StudioFMParameter,
                               value: Float) -> Bool {
        guard parameter.valid(value),
              runtime.first(where: { $0.id == id })?.fm != nil else {
            return false
        }
        let destination = StudioSynthModDestination.fm(parameter)
        return controlWorker()?.setBase(layer: id, destination: destination,
                                          value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }
}
