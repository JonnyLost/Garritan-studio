import Foundation
import AVFoundation
import AudioToolbox
import StudioFMDSP

/// Original, in-process Studio FM engine. Its C++ state lives for the
/// lifetime of AVAudioSourceNode's render callback; never destroy it
/// while the audio graph is connected.
public enum StudioFMError: Error, LocalizedError {
    case invalidConfiguration
    case unsupportedAudioBackend
    case invalidPatch

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Studio FM could not initialize its audio engine."
        case .unsupportedAudioBackend: return "Studio FM currently requires Studio's AVAudioEngine backend."
        case .invalidPatch: return "This Studio FM patch contains invalid parameter values."
        }
    }
}

private final class StudioFMRenderState {
    let synth: OpaquePointer
    init(_ synth: OpaquePointer) { self.synth = synth }
    deinit { sfm_destroy(synth) }
}

public final class StudioFMInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    private let state: StudioFMRenderState
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, voices: Int32 = 8) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
           let synth = sfm_create(sampleRate, voices) else {
            throw StudioFMError.invalidConfiguration
        }
        self.format = format
        let renderState = StudioFMRenderState(synth)
        state = renderState

        audioNode = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            sfm_render(renderState.synth, left, right, Int32(frameCount))
            return noErr
        }
    }

    @discardableResult
    public func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sfm_midi_event(state.synth, status, data1, data2, frameOffset) != 0
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
    public func controller(_ controller: UInt8, value: UInt8, channel: UInt8 = 0,
                           frameOffset: UInt32 = 0) -> Bool {
        midiMessage(status: 0xB0 | (channel & 0x0F), data1: controller,
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
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sfm_all_notes_off(state.synth) != 0
    }

    @discardableResult
    public func setParameter(_ parameter: StudioFMParameter, value: Float) -> Bool {
        guard parameter.valid(value) else { return false }
        return sfm_set_parameter(state.synth, parameter.rawValue, value) != 0
    }

    public func parameter(_ parameter: StudioFMParameter) -> Float {
        sfm_get_parameter(state.synth, parameter.rawValue)
    }

    /// This only runs on control/UI threads. DSP values are atomics;
    /// all render-buffer parameter snapshots remain valid.
    public func apply(_ patch: StudioFMPatch) throws {
        guard patch.validate() else { throw StudioFMError.invalidPatch }
        for parameter in StudioFMParameter.allCases {
            _ = setParameter(parameter, value: patch.value(for: parameter))
        }
    }
}
