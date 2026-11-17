import Foundation
import AVFoundation

/// Creates optional note-off trigger WAVs from the *real* release portion of
/// Auto Sampler's offline captures. All decoding/writing occurs after the
/// temporary AVAudioEngine has stopped, not on an audio callback.
///
/// This does not invent a generic fade: each release file starts at the exact
/// frame at which MIDI note-off was sent during the corresponding capture.
/// Existing sustained recordings remain intact and independently editable.
public enum StudioAutoSamplerReleaseCapture {
    public struct Result: Sendable {
        public let takes: [StudioSamplerFactoryTake]
        public let skippedCount: Int
        public var count: Int { takes.count }
    }

    public enum ReleaseError: Error, LocalizedError {
        case invalidConfiguration
        case invalidRecording

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "Release capture needs valid note lengths and a writable temporary directory."
            case .invalidRecording:
                return "A captured audio file has an invalid format or length for release extraction."
            }
        }
    }

    /// Extra sample zones can at most double the number of captured held notes.
    /// A native StudioSamplerPatch has a hard 128-zone limit.
    public static func fitsZoneLimit(heldSampleCount: Int,
                                     includeReleases: Bool) -> Bool {
        heldSampleCount > 0 && heldSampleCount <= 128 &&
        (!includeReleases || heldSampleCount <= 64)
    }

    public static func extract(from takes: [StudioSamplerFactoryTake],
                               sustainSeconds: Double, sampleRate: Double,
                               into directory: URL) throws -> Result {
        guard sustainSeconds.isFinite,
              (0.1...5).contains(sustainSeconds),
              [44_100.0, 48_000.0, 96_000.0].contains(sampleRate),
              !takes.isEmpty, takes.count <= 64 else {
            throw ReleaseError.invalidConfiguration
        }
        let held = Int(sustainSeconds * sampleRate)
        guard held >= 2 else { throw ReleaseError.invalidConfiguration }
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)

        var releases: [StudioSamplerFactoryTake] = []
        for take in takes {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            guard !take.releaseTrigger else { throw ReleaseError.invalidConfiguration }
            let name = "release-midi-\(take.rootNote)-velocity-\(take.velocity)-\(UUID().uuidString).wav"
            let output = directory.appendingPathComponent(name)
            do {
                if try extractOne(source: take.source, destination: output,
                                  heldFrames: held, sampleRate: sampleRate) {
                    releases.append(StudioSamplerFactoryTake(
                        source: output, rootNote: take.rootNote,
                        velocity: take.velocity,
                        microphoneID: take.microphoneID,
                        articulation: take.articulation,
                        releaseTrigger: true))
                } else {
                    try? FileManager.default.removeItem(at: output)
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        return Result(takes: releases,
                      skippedCount: takes.count - releases.count)
    }

    /// Prevent the same recorded note-off tail from sounding twice: once as
    /// the end of the held WAV and again as a native release-trigger zone.
    /// Original PCM stays intact for editing/reanalysis. This trim is applied
    /// only when release capture is enabled, even if a silent tail was skipped.
    /// Existing sustain-loop markers lie inside the held region.
    public static func separatingHeldAndReleasePlayback(
        in patch: StudioSamplerPatch, sustainSeconds: Double,
        sampleRate: Double) throws -> StudioSamplerPatch {
        guard sustainSeconds.isFinite, sampleRate.isFinite,
              sustainSeconds > 0, sampleRate > 0,
              sustainSeconds * sampleRate <= Double(UInt32.max) else {
            throw ReleaseError.invalidConfiguration
        }
        let heldFrames = UInt32(sustainSeconds * sampleRate)
        guard heldFrames >= 512 else { throw ReleaseError.invalidConfiguration }
        var result = patch
        for index in result.zones.indices where
            result.zones[index].isReleaseTrigger != true {
            var zone = result.zones[index]
            // The source WAV contains heldFrames followed by release audio.
            // Do not override an explicit shorter user-defined region.
            zone.trimEndFrame = min(zone.trimEndFrame ?? heldFrames, heldFrames)
            // Smooth the held recording's final edge, but keep the native
            // release zone's independent attack and fade unchanged.
            zone.fadeOutFrames = min(256, zone.trimEndFrame! / 4)
            guard zone.isValid else { throw ReleaseError.invalidRecording }
            result.zones[index] = zone
        }
        guard result.isValid else { throw ReleaseError.invalidRecording }
        return result
    }

    /// A short, non-destructive tail-end fade prevents discontinuities when
    /// a note-off recording ends before the source plugin fully decays. The
    /// already recorded PCM stays unchanged.
    public static func smoothingReleaseEndings(in patch: StudioSamplerPatch)
        -> StudioSamplerPatch {
        var result = patch
        for index in result.zones.indices where
            result.zones[index].isReleaseTrigger == true {
            result.zones[index].fadeOutFrames = 256
        }
        return result
    }

    /// Read and copy in blocks; never retain a full recording in memory.
    /// Reject effectively silent release tails rather than creating hundreds
    /// of empty release-trigger zones in percussion or synth patches.
    private static func extractOne(source: URL, destination: URL,
                                   heldFrames: Int, sampleRate: Double) throws -> Bool {
        let file = try AVAudioFile(
            forReading: source, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let format = file.processingFormat
        let available = Int(file.length) - heldFrames
        guard available >= 256 else { return false }
        guard (1...2).contains(Int(format.channelCount)),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              abs(format.sampleRate - sampleRate) <= 1
        else { throw ReleaseError.invalidRecording }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 4096) else {
            throw ReleaseError.invalidRecording
        }
        let writer = try AVAudioFile(
            forWriting: destination, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = AVAudioFramePosition(heldFrames)
        var remaining = available
        var peak = 0.0
        var energy = 0.0
        var measured = 0
        // Observe the first 150 ms, where an audible key-release or tail
        // should start. A delayed reverb alone is not sufficient here.
        let probeFrames = min(available, max(256, Int(sampleRate * 0.15)))
        while remaining > 0 {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            let requested = min(4096, remaining)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
            guard Int(buffer.frameLength) == requested,
                  let channels = buffer.floatChannelData else {
                throw ReleaseError.invalidRecording
            }
            let probe = min(requested, probeFrames - measured)
            if probe > 0 {
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<probe {
                        let value = Double(channels[channel][index])
                        guard value.isFinite else {
                            throw ReleaseError.invalidRecording
                        }
                        peak = max(peak, abs(value))
                        energy += value * value
                    }
                }
                measured += probe
            }
            try writer.write(from: buffer)
            remaining -= requested
        }
        guard measured > 0 else { return false }
        let rms = sqrt(energy / Double(measured * Int(format.channelCount)))
        return peak >= 0.001 && rms >= 0.0002
    }
}
