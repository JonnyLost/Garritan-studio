import Foundation
import AVFoundation
import AudioToolbox
import StudioSamplerDSP

public enum StudioSamplerError: Error, LocalizedError {
    case invalidConfiguration
    case invalidPatch
    case unsupportedAudioBackend
    case unsupportedSampleFormat(URL)
    case sampleTooLarge(URL)
    case invalidSample(URL)
    case couldNotLoadZone(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Studio Sampler could not initialize its native audio renderer."
        case .invalidPatch: return "The Studio Sampler instrument has invalid sample mapping."
        case .unsupportedAudioBackend: return "Studio Sampler currently requires the AVAudioEngine backend."
        case .unsupportedSampleFormat(let url): return "Studio Sampler requires mono or stereo audio: \(url.lastPathComponent)"
        case .sampleTooLarge(let url): return "This sample is too large for the first RAM-only sampler: \(url.lastPathComponent)"
        case .invalidSample(let url): return "The sample has no usable audio data: \(url.lastPathComponent)"
        case .couldNotLoadZone(let url): return "Studio Sampler could not load the sample: \(url.lastPathComponent)"
        }
    }
}

/// Only the render block and this wrapper own the underlying sampler.
/// Attachment must stop before the instrument's final release.
private final class StudioSamplerRenderState {
    let sampler: OpaquePointer
    init(_ sampler: OpaquePointer) { self.sampler = sampler }
    deinit { ss_destroy(sampler) }
}

/// Native Studio sample playback using the same track routing as Studio Analog.
/// Sample decoding and zone creation are completed synchronously BEFORE a
/// callback is attached. No file reads, Swift allocations, or locks in render.
public final class StudioSamplerInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    public let patch: StudioSamplerPatch
    private let renderState: StudioSamplerRenderState
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, patch: StudioSamplerPatch, voices: Int32 = 32) throws {
        guard patch.isValid else { throw StudioSamplerError.invalidPatch }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let sampler = ss_create(sampleRate, voices) else {
            throw StudioSamplerError.invalidConfiguration
        }

        // Swift owns the C++ sampler immediately, even if decoding throws.
        let state = StudioSamplerRenderState(sampler)
        var cumulativeFrames: Int64 = 0
        for zone in patch.zones {
            let url = zone.sampleURL
            let file = try AVAudioFile(
                forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let sourceFormat = file.processingFormat
            guard (1...2).contains(Int(sourceFormat.channelCount)),
                  sourceFormat.commonFormat == .pcmFormatFloat32,
                  !sourceFormat.isInterleaved else {
                throw StudioSamplerError.unsupportedSampleFormat(url)
            }
            guard file.length >= 2 else { throw StudioSamplerError.invalidSample(url) }
            guard file.length <= 10_000_000,
                  cumulativeFrames <= 32_000_000 - file.length else {
                throw StudioSamplerError.sampleTooLarge(url)
            }
            cumulativeFrames += file.length
            let count = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count) else {
                throw StudioSamplerError.invalidSample(url)
            }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength >= 2, let samples = buffer.floatChannelData else {
                throw StudioSamplerError.invalidSample(url)
            }
            let right: UnsafePointer<Float>? = sourceFormat.channelCount == 2
                ? UnsafePointer(samples[1]) : nil
            guard ss_add_zone(
                sampler, zone.rootNote, zone.lowestNote, zone.highestNote,
                zone.lowestVelocity, zone.highestVelocity, sourceFormat.sampleRate,
                samples[0], right, buffer.frameLength
            ) == 1 else {
                throw StudioSamplerError.couldNotLoadZone(url)
            }
        }
        // Prepare the controller state and crossfade mode before the
        // AVAudioSourceNode is attached or can start rendering.
        guard ss_set_cc1_crossfade(sampler, patch.cc1Crossfade == true ? 1 : 0) == 1,
              ss_control_change(sampler, 1, patch.dynamicsCC1 ?? 127, 0) == 1,
              ss_control_change(sampler, 11, patch.expressionCC11 ?? 127, 0) == 1 else {
            throw StudioSamplerError.invalidConfiguration
        }
        self.format = format
        self.patch = patch
        self.renderState = state
        self.audioNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            ss_render(state.sampler, left, right, Int32(frameCount))
            return noErr
        }
    }

    /// MIDI producers may arrive from both live playthrough and timeline
    /// queues. The NSLock is ONLY on producers, never the audio render thread.
    @discardableResult
    public func noteOn(_ note: UInt8, velocity: UInt8, channel: UInt8) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return ss_note_on(renderState.sampler, note, velocity, channel) == 1
    }

    @discardableResult
    public func noteOff(_ note: UInt8, channel: UInt8) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return ss_note_off(renderState.sampler, note, channel) == 1
    }

    /// MIDI producer serialization is outside of the render callback.
    @discardableResult
    public func controller(_ controller: UInt8, value: UInt8, channel: UInt8) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return ss_control_change(renderState.sampler, controller, value, channel) == 1
    }

    /// Changes the mode for newly triggered notes without rebuilding a
    /// multimegabyte sample set on the main thread.
    @discardableResult
    public func setCC1Crossfade(_ enabled: Bool) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return ss_set_cc1_crossfade(renderState.sampler, enabled ? 1 : 0) == 1
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return ss_all_notes_off(renderState.sampler) == 1
    }
}
