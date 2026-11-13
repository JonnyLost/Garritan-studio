import Foundation
import AVFoundation
import AudioToolbox
import StudioPhysicalDSP

public enum StudioPhysicalError: Error, LocalizedError {
    case invalidConfiguration
    case invalidPatch

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Physical Modeling could not create its native audio renderer."
        case .invalidPatch:
            return "Physical Modeling contains an invalid sound parameter."
        }
    }
}

/// Owns the native synth so a render callback never outlives its C++ state.
private final class StudioPhysicalRenderState {
    let synth: OpaquePointer
    init(_ synth: OpaquePointer) { self.synth = synth }
    deinit { spm_destroy(synth) }
}

/// Studio's native physical instrument: source node, per-layer MIDI and
/// atomic sound controls. No heap allocation, file I/O or Swift object
/// mutation occurs in the audio rendering callback.
public final class StudioPhysicalInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    private let state: StudioPhysicalRenderState
    // C++ SPSC queue requires serialization of MIDI producers, never consumers.
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, voices: Int32 = 8,
                patch: StudioPhysicalPatch = StudioPhysicalPatch()) throws {
        guard patch.validate() else { throw StudioPhysicalError.invalidPatch }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let synth = spm_create(sampleRate, voices) else {
            throw StudioPhysicalError.invalidConfiguration
        }
        let state = StudioPhysicalRenderState(synth)
        self.state = state
        self.format = format
        for parameter in StudioPhysicalParameter.allCases {
            guard spm_set_parameter(synth, parameter.rawValue,
                                    patch.value(for: parameter)) != 0 else {
                throw StudioPhysicalError.invalidPatch
            }
        }
        audioNode = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudio_ParamError }
            spm_render(state.synth, left, right, Int32(count))
            return noErr
        }
    }

    @discardableResult
    public func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return spm_midi_event(state.synth, status, data1, data2, frameOffset) != 0
    }

    @discardableResult
    public func noteOn(_ pitch: UInt8, velocity: UInt8,
                       channel: UInt8 = 0) -> Bool {
        midiMessage(status: 0x90 | (channel & 15), data1: pitch, data2: velocity)
    }

    @discardableResult
    public func noteOff(_ pitch: UInt8, channel: UInt8 = 0) -> Bool {
        midiMessage(status: 0x80 | (channel & 15), data1: pitch, data2: 0)
    }

    @discardableResult
    public func controller(_ cc: UInt8, value: UInt8,
                           channel: UInt8 = 0) -> Bool {
        midiMessage(status: 0xB0 | (channel & 15), data1: cc, data2: value)
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return spm_all_notes_off(state.synth) != 0
    }

    @discardableResult
    public func setParameter(_ parameter: StudioPhysicalParameter,
                             value: Float) -> Bool {
        parameter.valid(value) &&
            spm_set_parameter(state.synth, parameter.rawValue, value) != 0
    }

    public func parameter(_ parameter: StudioPhysicalParameter) -> Float {
        spm_get_parameter(state.synth, parameter.rawValue)
    }
}
