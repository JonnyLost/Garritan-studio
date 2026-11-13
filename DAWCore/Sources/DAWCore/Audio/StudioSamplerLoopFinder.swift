import Foundation
import AVFoundation

/// A non-destructive *suggestion*, not a guarantee of a transparent loop.
/// The user can inspect and adjust the markers before applying the mapping.
public struct StudioSamplerLoopSuggestion: Sendable {
    public let startFrame: UInt32
    public let endFrame: UInt32
    public let crossfadeFrames: UInt32
    public let mismatchScore: Double

    public init(startFrame: UInt32, endFrame: UInt32,
                crossfadeFrames: UInt32, mismatchScore: Double) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.crossfadeFrames = crossfadeFrames
        self.mismatchScore = mismatchScore
    }
}

/// Original native loop analysis based on short, bounded sample windows.
/// No third-party DSP, no entire-file read, no processing on audio callback.
/// A coarse search followed by local refinement seeks similar waveform shapes
/// at likely sustain entry/exit points, across both stereo channels.
public enum StudioSamplerLoopFinder {
    public enum FinderError: Error, LocalizedError {
        case tooShort
        case unsupportedAudio
        case noReliableMatch

        public var errorDescription: String? {
            switch self {
            case .tooShort: return "The selected playback region is too short for automatic looping."
            case .unsupportedAudio: return "Loop analysis requires a mono or stereo audio recording."
            case .noReliableMatch: return "No reliable loop boundary was found. Adjust the markers manually."
            }
        }
    }

    public static func suggest(url: URL, trimStart: UInt32? = nil,
                               trimEnd: UInt32? = nil) throws -> StudioSamplerLoopSuggestion {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else { throw FinderError.unsupportedAudio }

        let fileFrames = Int(file.length)
        let lower = Int(trimStart ?? 0)
        let upper = Int(trimEnd ?? UInt32(clamping: fileFrames))
        guard lower >= 0, upper <= fileFrames, upper - lower >= 512 else {
            throw FinderError.tooShort
        }
        let length = upper - lower
        let compareFrames = 24
        let radius = min(2_048, max(48, length / 18))
        let firstCenter = lower + length * 35 / 100
        let secondCenter = lower + length * 78 / 100
        let firstLow = max(lower + compareFrames, firstCenter - radius)
        let firstHigh = min(upper - compareFrames - 1, firstCenter + radius)
        let secondLow = max(firstHigh + compareFrames + 1, secondCenter - radius)
        let secondHigh = min(upper - compareFrames - 1, secondCenter + radius)
        guard firstHigh > firstLow, secondHigh > secondLow else {
            throw FinderError.tooShort
        }

        func readRange(start: Int, end: Int) throws -> [[Float]] {
            let size = end - start
            guard size > 0 else { throw FinderError.tooShort }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(size)
            ) else { throw FinderError.unsupportedAudio }
            file.framePosition = AVAudioFramePosition(start)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(size))
            guard Int(buffer.frameLength) == size,
                  let channels = buffer.floatChannelData else {
                throw FinderError.unsupportedAudio
            }
            return (0..<Int(format.channelCount)).map { channel in
                Array(UnsafeBufferPointer(start: channels[channel], count: size))
            }
        }

        // Read at most two windows of about 4,200 frames each, regardless of
        // how long the imported recording is.
        let firstOrigin = firstLow - compareFrames
        let secondOrigin = secondLow - compareFrames
        let first = try readRange(start: firstOrigin,
                                  end: firstHigh + compareFrames + 1)
        let second = try readRange(start: secondOrigin,
                                   end: secondHigh + compareFrames + 1)

        func score(start: Int, end: Int) -> Double {
            let fromIndex = end - secondOrigin - compareFrames
            let toIndex = start - firstOrigin
            var error = 0.0
            var energy = 0.0
            for channel in first.indices {
                for offset in 0..<compareFrames {
                    let a = Double(second[channel][fromIndex + offset])
                    let b = Double(first[channel][toIndex + offset])
                    let d = a - b
                    error += d * d
                    energy += a * a + b * b
                }
            }
            if energy < 1.0e-7 { return .infinity }
            return error / energy
        }

        var bestScore = Double.infinity
        var bestStart = firstCenter
        var bestEnd = secondCenter

        // Coarse scan with stride 8 to bound CPU use on a MacBook.
        for start in stride(from: firstLow, through: firstHigh, by: 8) {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            for end in stride(from: secondLow, through: secondHigh, by: 8) {
                let candidate = score(start: start, end: end)
                if candidate < bestScore {
                    bestScore = candidate
                    bestStart = start
                    bestEnd = end
                }
            }
        }

        // One-frame refinement around the best pair.
        let refineStartLow = max(firstLow, bestStart - 10)
        let refineStartHigh = min(firstHigh, bestStart + 10)
        let refineEndLow = max(secondLow, bestEnd - 10)
        let refineEndHigh = min(secondHigh, bestEnd + 10)
        for start in refineStartLow...refineStartHigh {
            for end in refineEndLow...refineEndHigh {
                let candidate = score(start: start, end: end)
                if candidate < bestScore {
                    bestScore = candidate
                    bestStart = start
                    bestEnd = end
                }
            }
        }

        // Low similarity is a poor automated recommendation. User can still
        // set loop points manually or choose another recording.
        guard bestScore.isFinite, bestScore < 0.50, bestEnd - bestStart >= 32 else {
            throw FinderError.noReliableMatch
        }
        let fade = min(256, (bestEnd - bestStart) / 8)
        return StudioSamplerLoopSuggestion(
            startFrame: UInt32(bestStart), endFrame: UInt32(bestEnd),
            crossfadeFrames: UInt32(fade), mismatchScore: bestScore
        )
    }
}
