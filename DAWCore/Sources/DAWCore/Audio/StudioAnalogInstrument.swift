import Foundation
import AVFoundation
import AudioToolbox
import StudioAnalogDSP

/// Errors from the original in-process synthesizer, not an installed Audio Unit.
public enum StudioAnalogError: Error, LocalizedError {
    case invalidConfiguration
    case unsupportedAudioBackend

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Studio Analog could not initialize its audio engine."
        case .unsupportedAudioBackend:
            return "Studio Analog currently requires Studio's AVAudioEngine backend."
        }
    }
}

/// A render-block-owned C++ instance. The AVAudioSourceNode keeps this object
/// alive as long as its render callback might still execute. Never free a
/// synthesizer directly from a UI action while the source node is attached.
private final class StudioAnalogRenderState {
    let synth: OpaquePointer

    init(_ synth: OpaquePointer) {
        self.synth = synth
    }

    deinit {
        sa_destroy(synth)
    }
}

/// Native, in-process instrument: no custom AU registration or plug-in install.
/// Audio runs exclusively on AVAudioEngine's render thread. MIDI producers are
/// serialized with an NSLock *outside* the audio callback because MIDI
/// playthrough and timeline playback can arrive from different threads.
/// The C++ queue itself is single-producer/single-consumer and lock-free.
public final class StudioAnalogInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    private let renderState: StudioAnalogRenderState
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, voices: Int32 = 8) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let synth = sa_create(sampleRate, voices) else {
            throw StudioAnalogError.invalidConfiguration
        }
        self.format = format
        let state = StudioAnalogRenderState(synth)
        self.renderState = state

        // Do not use a captured SwiftUI or @MainActor object inside this block.
        // The render state is retained by the callback, and the C++ renderer
        // performs no allocation, locking, logging or dispatch.
        self.audioNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            sa_render(state.synth, left, right, Int32(frameCount))
            return noErr
        }
    }

    /// MIDI is currently delivered at render-block boundaries. Precise event
    /// offsets, channel expression, sustain and pitch bend follow in later work.
    @discardableResult
    public func noteOn(_ note: UInt8, velocity: UInt8) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sa_note_on(renderState.synth, note, velocity) != 0
    }

    @discardableResult
    public func noteOff(_ note: UInt8) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sa_note_off(renderState.synth, note) != 0
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sa_all_notes_off(renderState.synth) != 0
    }

    @discardableResult
    public func setParameter(_ identifier: Int32, value: Float) -> Bool {
        sa_set_parameter(renderState.synth, identifier, value) != 0
    }

    public func parameter(_ identifier: Int32) -> Float {
        sa_get_parameter(renderState.synth, identifier)
    }
}
