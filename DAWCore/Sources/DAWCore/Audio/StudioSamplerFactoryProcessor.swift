import Foundation
import AVFoundation

/// Offline, nondestructive recording preparation. All decoding, metering and
/// encoding happen on a utility thread, never on the audio callback. Audio
/// is processed in fixed-size blocks (also for streamed orchestral takes).
public enum StudioSamplerFactoryProcessor {
    public struct Settings: Sendable {
        public var trimSilence: Bool
        public var silenceThresholdDB: Float
        public var attackPaddingMilliseconds: Double
        public var normalize: Bool
        public var targetPeakDB: Float
        public var fadeInMilliseconds: Double
        public var fadeOutMilliseconds: Double

        public init(trimSilence: Bool = true, silenceThresholdDB: Float = -55,
                    attackPaddingMilliseconds: Double = 5,
                    normalize: Bool = true, targetPeakDB: Float = -1,
                    fadeInMilliseconds: Double = 3,
                    fadeOutMilliseconds: Double = 15) {
            self.trimSilence = trimSilence
            self.silenceThresholdDB = silenceThresholdDB
            self.attackPaddingMilliseconds = attackPaddingMilliseconds
            self.normalize = normalize
            self.targetPeakDB = targetPeakDB
            self.fadeInMilliseconds = fadeInMilliseconds
            self.fadeOutMilliseconds = fadeOutMilliseconds
        }

        public var isValid: Bool {
            silenceThresholdDB.isFinite && (-100 ... -10).contains(silenceThresholdDB) &&
            targetPeakDB.isFinite && (-24 ... 0).contains(targetPeakDB) &&
            attackPaddingMilliseconds.isFinite &&
            (0 ... 250).contains(attackPaddingMilliseconds) &&
            fadeInMilliseconds.isFinite && (0 ... 500).contains(fadeInMilliseconds) &&
            fadeOutMilliseconds.isFinite && (0 ... 1500).contains(fadeOutMilliseconds)
        }
    }

    public struct Report: Sendable {
        public let url: URL
        public let sourceFrames: Int64
        public let outputFrames: Int64
        public let sampleRate: Double
        public let channels: Int
        public let peakBefore: Float
        public let gainApplied: Float
    }

    public enum FactoryError: Error, LocalizedError {
        case invalidSettings
        case unsupportedAudio
        case emptyRecording
        case noUsableSignal
        case destinationExists
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .invalidSettings: return "Instrument Factory audio preparation settings are invalid."
            case .unsupportedAudio: return "Recording must have mono or stereo decoded PCM audio."
            case .emptyRecording: return "Recording is empty or shorter than two samples."
            case .noUsableSignal: return "No signal above the configured threshold was found."
            case .destinationExists: return "Output already exists; choose a new filename."
            case .cancelled: return "Sample preparation was cancelled."
            }
        }
    }

    /// Analyze the complete original to locate its signal and peak. Stereo
    /// channels always share the same frame boundaries and normalization gain.
    /// The source file is never overwritten or modified.
    public static func prepare(source: URL, destination: URL,
                               settings: Settings = Settings()) throws -> Report {
        guard settings.isValid else { throw FactoryError.invalidSettings }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw FactoryError.destinationExists
        }
        let input = try AVAudioFile(forReading: source,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let rate = format.sampleRate
        guard (1...2).contains(channels) && rate > 0 &&
              format.commonFormat == .pcmFormatFloat32 &&
              !format.isInterleaved else { throw FactoryError.unsupportedAudio }
        guard input.length >= 2, input.length <= 500_000_000 else {
            throw FactoryError.emptyRecording
        }
        let capacity: AVAudioFrameCount = 8192
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw FactoryError.unsupportedAudio
        }

        let threshold = powf(10, settings.silenceThresholdDB / 20)
        let frameCount = Int64(input.length)
        var first = frameCount
        var last: Int64 = -1
        var absolute: Int64 = 0
        while absolute < frameCount {
            if Task<Never, Never>.isCancelled { throw FactoryError.cancelled }
            try input.read(into: block, frameCount: AVAudioFrameCount(min(
                Int64(capacity), frameCount - absolute)))
            let received = Int(block.frameLength)
            guard received > 0, let pcm = block.floatChannelData else {
                throw FactoryError.unsupportedAudio
            }
            for frame in 0..<received {
                var amplitude: Float = 0
                for channel in 0..<channels {
                    let value = pcm[channel][frame]
                    guard value.isFinite else { throw FactoryError.unsupportedAudio }
                    amplitude = max(amplitude, abs(value))
                }
                if amplitude >= threshold {
                    first = min(first, absolute + Int64(frame))
                    last = absolute + Int64(frame)
                }
            }
            absolute += Int64(received)
        }
        guard last >= first else { throw FactoryError.noUsableSignal }
        let padding = Int64(rate * settings.attackPaddingMilliseconds / 1000)
        let start = settings.trimSilence ? max(0, first - padding) : 0
        let end = settings.trimSilence ? min(frameCount, last + padding + 1) : frameCount
        guard end - start >= 2 else { throw FactoryError.emptyRecording }

        // Peak is calculated only for frames that survive trimming, so
        // discarded clicks cannot suppress useful normalization.
        input.framePosition = AVAudioFramePosition(start)
        var remaining = end - start
        var peak: Float = 0
        while remaining > 0 {
            if Task<Never, Never>.isCancelled { throw FactoryError.cancelled }
            try input.read(into: block,
                           frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
            let read = Int(block.frameLength)
            guard read > 0, let pcm = block.floatChannelData else {
                throw FactoryError.unsupportedAudio
            }
            for channel in 0..<channels {
                for frame in 0..<read { peak = max(peak, abs(pcm[channel][frame])) }
            }
            remaining -= Int64(read)
        }
        guard peak > 0, peak.isFinite else { throw FactoryError.noUsableSignal }
        let target = powf(10, settings.targetPeakDB / 20)
        // Do not amplify quiet background hiss indefinitely. A ceiling also
        // guards malformed recordings with extreme, near-zero values.
        let gain = settings.normalize ? min(8, target / peak) : 1
        let length = end - start
        let inFrames = min(length / 2, Int64(rate * settings.fadeInMilliseconds / 1000))
        let outFrames = min(length / 2, Int64(rate * settings.fadeOutMilliseconds / 1000))
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".factory-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: staging) }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: staging,
                                         settings: outputSettings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            input.framePosition = AVAudioFramePosition(start)
            var written: Int64 = 0
            while written < length {
                if Task<Never, Never>.isCancelled { throw FactoryError.cancelled }
                try input.read(into: block, frameCount: AVAudioFrameCount(min(
                    Int64(capacity), length - written)))
                let received = Int(block.frameLength)
                guard received > 0, let pcm = block.floatChannelData else {
                    throw FactoryError.unsupportedAudio
                }
                for frame in 0..<received {
                    let absolute = written + Int64(frame)
                    var volume = gain
                    if inFrames > 0 && absolute < inFrames {
                        volume *= Float(absolute + 1) / Float(inFrames)
                    }
                    if outFrames > 0 && absolute >= length - outFrames {
                        volume *= Float(length - absolute) / Float(outFrames)
                    }
                    for channel in 0..<channels {
                        pcm[channel][frame] = max(-1, min(1,
                            pcm[channel][frame] * volume))
                    }
                }
                try writer.write(from: block)
                written += Int64(received)
            }
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw FactoryError.destinationExists
        }
        try fm.moveItem(at: staging, to: destination)
        return Report(url: destination, sourceFrames: frameCount,
                      outputFrames: length, sampleRate: rate,
                      channels: channels, peakBefore: peak,
                      gainApplied: gain)
    }
}
