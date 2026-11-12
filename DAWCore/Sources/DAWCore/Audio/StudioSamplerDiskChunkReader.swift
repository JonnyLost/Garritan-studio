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
    public static let readAheadPages = 2 // matches the native two-page-per-voice cache
    public static let maxReadFrames = pageFrames * 4 // per-worker I/O request bound
    public static let attackSeconds = 0.25

    public static func attackFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return pageFrames }
        return max(pageFrames, min(32_768, Int((sampleRate * attackSeconds).rounded(.up))))
    }

    public static func readAheadBytes(voices: Int, channels: Int = 2) -> Int {
        max(0, min(voices, 64)) * pageFrames * readAheadPages *
            max(1, min(channels, 2)) *
            MemoryLayout<Float>.stride
    }
}

/// A worker-owned AVAudioFile page reader. One reusable scratch buffer is
/// allocated when the reader opens; pages do not allocate decode buffers.
/// 
/// IMPORTANT: instance is not Sendable and is deliberately thread-confined.
/// Call exclusively on a dedicated background worker, NEVER from AVAudioSourceNode
/// render callback or main-actor UI. The audio engine consumes copied pages
/// via the C++ streaming-slot ownership protocol.
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
    private let scratch: AVAudioPCMBuffer
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
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(StudioSamplerStreamBudget.maxReadFrames)
        ) else { throw ReaderError.readFailed }
        self.file = file
        self.scratch = scratch
        self.frameCount = file.length
        self.sampleRate = format.sampleRate
        self.channels = Int(format.channelCount)
    }

    /// A direct, no-copy view into the reader-owned scratch buffer, valid
    /// only for the duration of the synchronous worker callback. The worker
    /// copies the page into C++ memory before returning. Never retain the
    /// pointers or use this reader on multiple threads.
    public func withPage<Result>(
        startFrame: Int64,
        requestedFrames: Int = StudioSamplerStreamBudget.pageFrames,
        _ consumer: (UnsafePointer<Float>, UnsafePointer<Float>?, Int) -> Result
    ) throws -> Result {
        guard startFrame >= 0, startFrame < frameCount,
              requestedFrames > 0,
              requestedFrames <= StudioSamplerStreamBudget.maxReadFrames else {
            throw ReaderError.invalidRange
        }
        let count = Int(min(Int64(requestedFrames), frameCount - startFrame))
        file.framePosition = AVAudioFramePosition(startFrame)
        try file.read(into: scratch, frameCount: AVAudioFrameCount(count))
        let actual = Int(scratch.frameLength)
        guard actual > 0, actual <= count, let data = scratch.floatChannelData else {
            throw ReaderError.readFailed
        }
        let right: UnsafePointer<Float>? = channels == 2
            ? UnsafePointer(data[1]) : nil
        return consumer(UnsafePointer(data[0]), right, actual)
    }

    /// Public immutable page copy for analysis, tests and non-realtime code.
    /// Streaming playback uses withPage to avoid these intermediate arrays.
    public func readPage(
        startFrame: Int64,
        requestedFrames: Int = StudioSamplerStreamBudget.pageFrames
    ) throws -> StudioSamplerPCMPage {
        let copied = try withPage(
            startFrame: startFrame, requestedFrames: requestedFrames
        ) { left, right, count in
            let l = Array(UnsafeBufferPointer(start: left, count: count))
            let r = right.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? l
            return (count, l, r)
        }
        return StudioSamplerPCMPage(
            startFrame: startFrame, frameCount: copied.0,
            sampleRate: sampleRate, left: copied.1, right: copied.2
        )
    }
}
