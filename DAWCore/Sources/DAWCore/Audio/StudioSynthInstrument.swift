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

    var source: AVAudioNode {
        if let analog { return analog.audioNode }
        if let fm { return fm.audioNode }
        return wavetable!.audioNode
    }
    var format: AVAudioFormat {
        if let analog { return analog.format }
        if let fm { return fm.format }
        return wavetable!.format
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
        case .fm:
            let synth = try StudioFMInstrument(sampleRate: sampleRate)
            try synth.apply(layer.fmPatch ?? StudioFMPatch())
            analog = nil
            fm = synth
            wavetable = nil
        case .wavetable:
            let synth = try StudioWavetableInstrument(sampleRate: sampleRate)
            try synth.apply(layer.wavetablePatch ?? StudioWavetablePatch())
            analog = nil
            fm = nil
            wavetable = synth
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
        return wavetable!.midiMessage(status: status, data1: data1,
                                      data2: data2, frameOffset: frameOffset)
    }

    func allNotesOff() -> Bool {
        if let analog { return analog.allNotesOff() }
        if let fm { return fm.allNotesOff() }
        return wavetable!.allNotesOff()
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

    public init(sampleRate: Double, patch: StudioSynthPatch) throws {
        guard patch.validate() else { throw StudioSynthError.invalidPatch }
        self.patch = patch
        runtime = try patch.layers.filter(\.enabled).map {
            try StudioSynthRuntimeLayer($0, sampleRate: sampleRate)
        }
        if let settings = patch.modulation, settings.hasEnabledRoutes {
            createModulationWorker(settings)
        }
    }

    private func createModulationWorker(_ settings: StudioSynthModulationSettings) {
        modulationWorker = StudioSynthModulationWorker(
            settings: settings,
            read: { [weak self] id, destination in
                self?.directParameter(id: id, destination: destination)
            },
            write: { [weak self] id, destination, value in
                self?.writeParameter(id: id, destination: destination, value: value)
                    ?? false
            })
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
        }
    }

    /// Live cross-layer routing does not rebuild the audio graph, stop playback
    /// or reset voices. A 50Hz worker is active only while routes are enabled.
    @discardableResult
    public func setModulation(_ settings: StudioSynthModulationSettings) -> Bool {
        guard settings.validate(layers: patch.layers) else { return false }
        if let worker = modulationWorker {
            worker.update(settings)
            if !settings.hasEnabledRoutes { modulationWorker = nil }
        } else if settings.hasEnabledRoutes {
            createModulationWorker(settings)
        }
        return true
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
        modulationWorker?.receiveMIDI(status: status, data1: data1, data2: data2)
        return accepted
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
        modulationWorker?.panic()
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
        return modulationWorker?.setBase(layer: id, destination: destination,
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
        return modulationWorker?.setBase(layer: id, destination: destination,
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
        return modulationWorker?.setBase(layer: id, destination: destination,
                                          value: value) ??
            writeParameter(id: id, destination: destination, value: value)
    }
}
