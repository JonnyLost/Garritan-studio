import Foundation
import AVFoundation
import AudioToolbox
import StudioAnalogDSP

/// Errors from the original in-process synthesizer, not an installed Audio Unit.
public enum StudioAnalogError: Error, LocalizedError {
    case invalidConfiguration
    case unsupportedAudioBackend
    case invalidRouting
    case routingBusy

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Studio Analog could not initialize its audio engine."
        case .unsupportedAudioBackend:
            return "Studio Analog currently requires Studio's AVAudioEngine backend."
        case .invalidRouting:
            return "Invalid cable: check signal types, input occupancy, cycles and output path."
        case .routingBusy:
            return "The previous graph update is still waiting for an audio buffer. Try again."
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

    /// Relative sample offsets refer to the next source-node render call.
    /// The caller must submit ahead of that callback; late MIDI from a
    /// UI/transport worker is played at the next buffer rather than backdated.
    /// This lock only serializes producers; it is never taken by the callback.
    @discardableResult
    public func midiMessage(status: UInt8, data1: UInt8, data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sa_midi_event(renderState.synth, status, data1, data2, frameOffset) != 0
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
    public func pitchBend(_ rawValue: UInt16, channel: UInt8 = 0,
                          frameOffset: UInt32 = 0) -> Bool {
        guard rawValue <= 16_383 else { return false }
        return midiMessage(status: 0xE0 | (channel & 0x0F),
                           data1: UInt8(rawValue & 0x7F),
                           data2: UInt8((rawValue >> 7) & 0x7F),
                           frameOffset: frameOffset)
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sa_all_notes_off(renderState.synth) != 0
    }

    /// Validate a new modular routing off the audio thread, then publish an
    /// immutable graph at the next render boundary. The caller must serialize
    /// all submissions, currently through ProjectViewModel's MainActor.
    public func setRouting(_ connections: [StudioAnalogConnection]) throws {
        guard StudioAnalogConnection.preliminarilyValid(connections) else {
            throw StudioAnalogError.invalidRouting
        }
        let routes = connections.map { cable in
            SARoute(source: cable.source.rawValue,
                    destination: cable.destination.rawValue,
                    destinationInput: cable.input, gain: cable.gain)
        }
        let result = routes.withUnsafeBufferPointer { pointer in
            sa_submit_patch(renderState.synth, pointer.baseAddress, pointer.count)
        }
        switch result {
        case 1: return
        case -1: throw StudioAnalogError.routingBusy
        default: throw StudioAnalogError.invalidRouting
        }
    }

    /// Restores every parameter atomically before a newly attached synth
    /// begins rendering; this never modifies the modular audio graph.
    public func apply(_ patch: StudioAnalogPatch) {
        for parameter in StudioAnalogParameter.allCases {
            _ = setParameter(parameter.rawValue, value: patch.value(for: parameter))
        }
    }

    @discardableResult
    public func setParameter(_ identifier: Int32, value: Float) -> Bool {
        sa_set_parameter(renderState.synth, identifier, value) != 0
    }

    public func parameter(_ identifier: Int32) -> Float {
        sa_get_parameter(renderState.synth, identifier)
    }
}
