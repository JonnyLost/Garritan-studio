import Foundation
import AVFoundation

/// Immutable PCM page produced by a disk/decoding worker. The realtime
/// renderer must never create or request one synchronously.
public struct StudioSamplerPCMPage: Sendable {
    public let startFrame: Int64
    public let frameCount: Int
    public let sampleRate: Double
    public let left: [Float]
    public let right: [Float]
}

/// Memory budget for the future per-voice read-ahead ring. These limits
/// prevent a large orchestral session from multiplying unbounded PCM caches.
public enum StudioSamplerStreamBudget {
    public static let pageFrames = 4_096
    public static let readAheadPages = 4
    public static let maxReadFrames = pageFrames * readAheadPages
    public static let attackSeconds = 0.25

    public static func attackFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return pageFrames }
        return max(pageFrames, min(32_768, Int((sampleRate * attackSeconds).rounded(.up))))
    }

    public static func readAheadBytes(voices: Int, channels: Int = 2) -> Int {
        max(0, min(voices, 64)) * maxReadFrames * max(1, min(channels, 2)) *
            MemoryLayout<Float>.stride
    }
}

/// A worker-owned native AVAudioFile page reader. Only initializes format
/// metadata; does not preload sample PCM. Every read has a fixed memory cap.
/// 
/// IMPORTANT: instance is not Sendable and is deliberately thread-confined.
/// Call exclusively on a dedicated background worker, NEVER from AVAudioSourceNode
/// render callback or main-actor UI. The DSP read-ahead bridge is a separate
/// integration milestone and not claimed here.
public final class StudioSamplerDiskChunkReader {
    public enum ReaderError: Error, LocalizedError {
        case unsupportedChannels
        case invalidRange
        case emptyRecording
        case readFailed

        public var errorDescription: String? {
            switch self {
            case .unsupportedChannels:
                return "Disk sampler supports mono and stereo recordings."
            case .invalidRange:
                return "Requested sample page is outside the recording or memory budget."
            case .emptyRecording:
                return "The recording contains no playable audio frames."
            case .readFailed:
                return "Could not read the requested audio page."
            }
        }
    }

    private let file: AVAudioFile
    public let frameCount: Int64
    public let sampleRate: Double
    public let channels: Int

    public init(url: URL) throws {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved, (1...2).contains(Int(format.channelCount)) else {
            throw ReaderError.unsupportedChannels
        }
        guard file.length >= 2 else { throw ReaderError.emptyRecording }
        self.file = file
        self.frameCount = file.length
        self.sampleRate = format.sampleRate
        self.channels = Int(format.channelCount)
    }

    /// Seek and decode only the requested 1...16384 source frames. A short
    /// final page is valid and returned with its actual decoded frame count.
    /// The caller controls prefetch priority and can retry after I/O errors.
    public func readPage(startFrame: Int64,
                         requestedFrames: Int = StudioSamplerStreamBudget.pageFrames)
        throws -> StudioSamplerPCMPage
    {
        guard startFrame >= 0, startFrame < frameCount,
              requestedFrames > 0,
              requestedFrames <= StudioSamplerStreamBudget.maxReadFrames else {
            throw ReaderError.invalidRange
        }
        let count = Int(min(Int64(requestedFrames), frameCount - startFrame))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)
        ) else { throw ReaderError.readFailed }
        file.framePosition = AVAudioFramePosition(startFrame)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        let actual = Int(buffer.frameLength)
        guard actual > 0, actual <= count, let data = buffer.floatChannelData else {
            throw ReaderError.readFailed
        }
        let left = Array(UnsafeBufferPointer(start: data[0], count: actual))
        let right: [Float]
        if channels == 2 {
            right = Array(UnsafeBufferPointer(start: data[1], count: actual))
        } else {
            right = left
        }
        return StudioSamplerPCMPage(startFrame: startFrame, frameCount: actual,
                                    sampleRate: sampleRate, left: left, right: right)
    }
}
