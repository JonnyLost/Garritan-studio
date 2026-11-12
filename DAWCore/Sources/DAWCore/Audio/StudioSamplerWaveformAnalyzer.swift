import Foundation
import AVFoundation

/// Reduced waveform envelope for display only. A fixed number of peak
/// columns avoids retaining complete decoded audio in the UI.
public struct StudioSamplerWaveformData: Sendable {
    public let totalFrames: Int
    public let sampleRate: Double
    public let peaks: [Float]

    public init(totalFrames: Int, sampleRate: Double, peaks: [Float]) {
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.peaks = peaks
    }
}

/// Read sample peaks on a background worker, never the audio render thread.
/// Blocks are decoded in small bounded chunks, not a whole-file UI buffer.
public enum StudioSamplerWaveformAnalyzer {
    public enum AnalysisError: Error, LocalizedError {
        case emptyAudio
        case unsupportedAudio
        case fileTooLarge

        public var errorDescription: String? {
            switch self {
            case .emptyAudio: return "No usable audio frames found in this sample."
            case .unsupportedAudio: return "Waveform editor supports mono/stereo PCM audio."
            case .fileTooLarge: return "This sample exceeds the current 10-million-frame limit."
            }
        }
    }

    public static func analyze(url: URL, columns: Int = 1200) throws -> StudioSamplerWaveformData {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else { throw AnalysisError.unsupportedAudio }
        guard file.length >= 2 else { throw AnalysisError.emptyAudio }
        guard file.length <= 10_000_000 else { throw AnalysisError.fileTooLarge }

        let frames = Int(file.length)
        let count = max(1, min(4096, columns))
        var peaks = [Float](repeating: 0, count: count)
        let capacity: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AnalysisError.unsupportedAudio
        }
        var processed = 0
        while processed < frames {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            let countToRead = min(Int(capacity), frames - processed)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(countToRead))
            let received = Int(buffer.frameLength)
            guard received > 0, let channels = buffer.floatChannelData else { break }
            for offset in 0..<received {
                let absolute = processed + offset
                let bucket = min(count - 1,
                                 Int(Int64(absolute) * Int64(count) / Int64(frames)))
                let value = abs(channels[0][offset])
                let peak = format.channelCount == 2
                    ? max(value, abs(channels[1][offset])) : value
                if peak.isFinite { peaks[bucket] = max(peaks[bucket], peak) }
            }
            processed += received
        }
        guard processed > 0 else { throw AnalysisError.emptyAudio }
        return StudioSamplerWaveformData(
            totalFrames: frames, sampleRate: format.sampleRate, peaks: peaks
        )
    }
}
