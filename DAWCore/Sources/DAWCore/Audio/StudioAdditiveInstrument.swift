import Foundation
import AVFoundation
import AudioToolbox
import StudioAdditiveDSP

public enum StudioAdditiveError: Error, LocalizedError {
    case invalidConfiguration, invalidPatch
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Studio Additive could not initialize its native renderer."
        case .invalidPatch:
            return "Studio Additive sound has invalid harmonic parameters."
        }
    }
}

/// Lives as long as the native AVAudioSourceNode render callback can run.
private final class StudioAdditiveRenderState {
    let synth: OpaquePointer
    init(_ synth: OpaquePointer) { self.synth = synth }
    deinit { sadd_destroy(synth) }
}

/// Original native harmonic synthesis, routed into Studio's existing
/// instrument mixer. MIDI producers are serialised outside the callback.
public final class StudioAdditiveInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    private let state: StudioAdditiveRenderState
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, voices: Int32 = 8) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let synth = sadd_create(sampleRate, voices) else {
            throw StudioAdditiveError.invalidConfiguration
        }
        self.format = format
        let state = StudioAdditiveRenderState(synth)
        self.state = state
        audioNode = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            sadd_render(state.synth, left, right, Int32(count))
            return noErr
        }
    }

    @discardableResult
    public func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sadd_midi_event(state.synth, status, data1, data2, frameOffset) != 0
    }

    @discardableResult
    public func noteOn(_ note: UInt8, velocity: UInt8, channel: UInt8 = 0,
                       frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0x90 | (channel & 0x0f), data1: note,
                    data2: velocity, frameOffset: frameOffset)
    }

    @discardableResult
    public func noteOff(_ note: UInt8, channel: UInt8 = 0,
                        frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0x80 | (channel & 0x0f), data1: note,
                    data2: 0, frameOffset: frameOffset)
    }

    @discardableResult
    public func controller(_ number: UInt8, value: UInt8, channel: UInt8 = 0,
                           frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0xB0 | (channel & 0x0f), data1: number,
                    data2: value, frameOffset: frameOffset)
    }

    @discardableResult
    public func pitchBend(_ value: UInt16, channel: UInt8 = 0,
                          frameOffset: UInt32 = 0) -> Bool {
        guard value <= 16_383 else { return false }
        return midiMessage(status: 0xE0 | (channel & 0x0f),
                           data1: UInt8(value & 0x7f),
                           data2: UInt8((value >> 7) & 0x7f),
                           frameOffset: frameOffset)
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sadd_all_notes_off(state.synth) != 0
    }

    @discardableResult
    public func setParameter(_ parameter: StudioAdditiveParameter, value: Float) -> Bool {
        guard parameter.valid(value) else { return false }
        return sadd_set_parameter(state.synth, parameter.rawValue, value) != 0
    }

    public func parameter(_ parameter: StudioAdditiveParameter) -> Float {
        sadd_get_parameter(state.synth, parameter.rawValue)
    }

    public func apply(_ patch: StudioAdditivePatch) throws {
        guard patch.validate() else { throw StudioAdditiveError.invalidPatch }
        for parameter in StudioAdditiveParameter.allCases {
            _ = setParameter(parameter, value: patch.value(for: parameter))
        }
    }
}
