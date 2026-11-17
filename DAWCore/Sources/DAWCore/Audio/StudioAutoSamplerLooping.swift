import Foundation
import AVFoundation

/// Conservative, non-destructive sustain-loop detection for newly recorded
/// Auto Sampler WAVs. All I/O and waveform analysis happen after the isolated
/// Audio Unit render engine stops, never inside a real-time callback.
///
/// No loop is written to a source WAV: the native sampler's existing playback
/// markers and crossfade renderer do all looping. Short, decaying, noisy or
/// low-confidence recordings remain ordinary one-shots.
public enum StudioAutoSamplerLooping {
    public struct Key: Hashable, Sendable {
        public let note: UInt8
        public let velocity: UInt8

        public init(note: UInt8, velocity: UInt8) {
            self.note = note
            self.velocity = velocity
        }
    }

    public struct Analysis: Sendable {
        public let attempted: Int
        public let recommendations: [Key: StudioSamplerLoopSuggestion]
        public var suggested: Int { recommendations.count }
        public var skipped: Int { attempted - recommendations.count }

        public init(attempted: Int,
                    recommendations: [Key: StudioSamplerLoopSuggestion]) {
            self.attempted = attempted
            self.recommendations = recommendations
        }
    }

    /// A long enough, stable held note is required before applying a loop.
    /// Include neither the initial attack nor the recorded note-off tail in
    /// the search. The loop finder compares short windows across both channels.
    private static let minimumSustainSeconds = 0.8
    private static let maximumMismatchScore = 0.10

    /// Optional, fallible analysis: a poor loop is NOT a capture failure.
    /// Returns no suggestion for decaying sounds, short notes or unmatched
    /// waveforms, while propagating user cancellation immediately.
    public static func analyze(takes: [StudioSamplerFactoryTake],
                               sustainSeconds: Double,
                               sampleRate: Double) throws -> Analysis {
        guard !takes.isEmpty, sustainSeconds.isFinite,
              sampleRate.isFinite, sampleRate > 0 else {
            return Analysis(attempted: takes.count, recommendations: [:])
        }
        let heldFrames = Int(sustainSeconds * sampleRate)
        guard sustainSeconds >= minimumSustainSeconds,
              heldFrames >= 512, heldFrames <= Int(UInt32.max) else {
            return Analysis(attempted: takes.count, recommendations: [:])
        }

        var suggestions: [Key: StudioSamplerLoopSuggestion] = [:]
        for take in takes {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            // Failed analysis must not prevent the composer from saving a
            // usable, non-looped instrument. The original take is retained.
            do {
                guard try hasStableSustain(take.source,
                                           heldFrames: heldFrames,
                                           expectedSampleRate: sampleRate)
                else { continue }
                let proposed = try StudioSamplerLoopFinder.suggest(
                    url: take.source,
                    trimStart: UInt32(heldFrames * 25 / 100),
                    trimEnd: UInt32(heldFrames * 90 / 100))
                guard proposed.mismatchScore.isFinite,
                      proposed.mismatchScore <= maximumMismatchScore,
                      proposed.endFrame <= UInt32(heldFrames * 90 / 100),
                      proposed.startFrame < proposed.endFrame else { continue }
                suggestions[Key(note: take.rootNote,
                                velocity: take.velocity)] = proposed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Recording remains playable as a one-shot. An unreliable
                // suggestion is never a reason to corrupt a native package.
            }
        }
        return Analysis(attempted: takes.count, recommendations: suggestions)
    }

    /// Map suggestions to the factory's actual velocity partitions rather
    /// than relying on take ordering. A failed candidate leaves the original
    /// zone intact. A loop is never installed on a release-trigger zone.
    public static func apply(_ analysis: Analysis, to patch: StudioSamplerPatch,
                             takes: [StudioSamplerFactoryTake])
        -> (patch: StudioSamplerPatch, loopCount: Int) {
        var updated = patch
        var count = 0
        for take in takes {
            let key = Key(note: take.rootNote, velocity: take.velocity)
            guard let suggestion = analysis.recommendations[key] else { continue }
            guard let zoneIndex = updated.zones.indices.first(where: {
                let zone = updated.zones[$0]
                return zone.rootNote == take.rootNote &&
                    zone.lowestVelocity <= take.velocity &&
                    zone.highestVelocity >= take.velocity &&
                    zone.isReleaseTrigger != true && !zone.hasSustainLoop
            }) else { continue }

            var candidate = updated.zones[zoneIndex]
            candidate.loopStartFrame = suggestion.startFrame
            candidate.loopEndFrame = suggestion.endFrame
            candidate.loopCrossfadeFrames = suggestion.crossfadeFrames
            guard candidate.isValid else { continue }
            updated.zones[zoneIndex] = candidate
            count += 1
        }
        guard updated.isValid else { return (patch, 0) }
        return (updated, count)
    }

    /// Read two small RMS windows from the held portion of the take. This
    /// rejects decaying instruments that happen to have a mathematically
    /// similar waveform during their fading tail.
    private static func hasStableSustain(_ url: URL, heldFrames: Int,
                                         expectedSampleRate: Double) throws -> Bool {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              abs(format.sampleRate - expectedSampleRate) < 1,
              Int(file.length) >= heldFrames else { return false }

        func rms(center: Int) throws -> Double {
            let window = min(2_048, heldFrames / 10)
            let start = max(0, min(Int(file.length) - window,
                                   center - window / 2))
            guard window > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(window))
            else { return 0 }
            file.framePosition = AVAudioFramePosition(start)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(window))
            guard Int(buffer.frameLength) == window,
                  let channels = buffer.floatChannelData else { return 0 }
            var energy = 0.0
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<window {
                    let value = Double(channels[channel][index])
                    guard value.isFinite else { return 0 }
                    energy += value * value
                }
            }
            return sqrt(energy / Double(window * Int(format.channelCount)))
        }

        let earlier = try rms(center: heldFrames / 4)
        let later = try rms(center: heldFrames * 3 / 4)
        guard earlier >= 0.0005, later >= 0.0005 else { return false }
        let ratio = later / earlier
        return ratio >= 0.55 && ratio <= 1.8
    }
}
