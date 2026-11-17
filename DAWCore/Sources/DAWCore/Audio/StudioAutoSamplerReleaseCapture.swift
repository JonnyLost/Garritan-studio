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
        guard sustainSeconds.isFinite, sustainSeconds >= 0.1,
              sampleRate.isFinite, sampleRate > 0,
              takes.count <= 64 else { throw ReleaseError.invalidConfiguration }
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
                        velocity: take.velocity, releaseTrigger: true))
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
