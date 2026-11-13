import Foundation
import AVFoundation
import AudioToolbox
import StudioWavetableDSP

public enum StudioWavetableError: Error, LocalizedError {
    case invalidConfiguration, invalidPatch
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Studio Wavetable could not create its native audio renderer."
        case .invalidPatch: return "Studio Wavetable patch has invalid parameter values."
        }
    }
}

/// The AVAudioSourceNode closure retains this render state until safe to destroy.
private final class StudioWavetableRenderState {
    let synth: OpaquePointer
    init(_ synth: OpaquePointer) { self.synth = synth }
    deinit { sws_destroy(synth) }
}

/// Original in-process wavetable renderer. No external plug-ins or sample files.
public final class StudioWavetableInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    private let state: StudioWavetableRenderState
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, voices: Int32 = 8) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved, let synth = sws_create(sampleRate, voices) else {
            throw StudioWavetableError.invalidConfiguration
        }
        self.format = format
        let state = StudioWavetableRenderState(synth)
        self.state = state
        audioNode = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            sws_render(state.synth, l, r, Int32(count))
            return noErr
        }
    }

    @discardableResult
    public func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sws_midi_event(state.synth, status, data1, data2, frameOffset) != 0
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
        midiMessage(status: 0xb0 | (channel & 0x0f), data1: number,
                    data2: value, frameOffset: frameOffset)
    }
    @discardableResult
    public func pitchBend(_ value: UInt16, channel: UInt8 = 0,
                          frameOffset: UInt32 = 0) -> Bool {
        guard value <= 16_383 else { return false }
        return midiMessage(status: 0xe0 | (channel & 0x0f),
                           data1: UInt8(value & 0x7f),
                           data2: UInt8((value >> 7) & 0x7f),
                           frameOffset: frameOffset)
    }
    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sws_all_notes_off(state.synth) != 0
    }
    @discardableResult
    public func setParameter(_ parameter: StudioWavetableParameter, value: Float) -> Bool {
        guard parameter.valid(value) else { return false }
        return sws_set_parameter(state.synth, parameter.rawValue, value) != 0
    }
    public func parameter(_ parameter: StudioWavetableParameter) -> Float {
        sws_get_parameter(state.synth, parameter.rawValue)
    }
    public func apply(_ patch: StudioWavetablePatch) throws {
        guard patch.validate() else { throw StudioWavetableError.invalidPatch }
        for param in StudioWavetableParameter.allCases {
            _ = setParameter(param, value: patch.value(for: param))
        }
    }
}
