import Foundation
import AVFoundation
import AudioToolbox

/// Offline multisampling of an original Studio Synth patch. It produces
/// regular WAV files, delegates the key/velocity mapping to the existing
/// Sampler Instrument Factory, and archives a portable .studioinstrument.
/// The live track and audio engine are never stopped or modified.
public enum StudioSynthSamplerCapture {
    public struct Options: Sendable {
        public var rootNotes: [UInt8]
        public var velocities: [UInt8]
        public var sustainSeconds: Double
        public var releaseSeconds: Double
        public var sampleRate: Double

        public init(rootNotes: [UInt8] = [48, 60, 72],
                    velocities: [UInt8] = [64, 112],
                    sustainSeconds: Double = 1.5,
                    releaseSeconds: Double = 0.65,
                    sampleRate: Double = 44_100) {
            self.rootNotes = rootNotes
            self.velocities = velocities
            self.sustainSeconds = sustainSeconds
            self.releaseSeconds = releaseSeconds
            self.sampleRate = sampleRate
        }

        public var isValid: Bool {
            !rootNotes.isEmpty && !velocities.isEmpty &&
                rootNotes.count * velocities.count <= 128 &&
                Set(rootNotes).count == rootNotes.count &&
                Set(velocities).count == velocities.count &&
                velocities.allSatisfy { $0 > 0 && $0 <= 127 } &&
                sustainSeconds.isFinite && (0.1...5).contains(sustainSeconds) &&
                releaseSeconds.isFinite && (0.1...3).contains(releaseSeconds) &&
                [44_100.0, 48_000.0, 96_000.0].contains(sampleRate)
        }
    }

    public struct Result: Sendable {
        public let patch: StudioSamplerPatch
        public let packageURL: URL
        public let takeCount: Int
    }

    public enum CaptureError: Error, LocalizedError {
        case invalidOptions
        case cannotPrepareAudio
        case renderingFailed
        case silentOutput

        public var errorDescription: String? {
            switch self {
            case .invalidOptions:
                return "Choose valid pitches, velocities and note lengths for capture."
            case .cannotPrepareAudio:
                return "Studio could not prepare the offline synthesizer recording."
            case .renderingFailed:
                return "The offline synth stopped producing audio during capture."
            case .silentOutput:
                return "The selected Synth patch produced silence; no instrument was saved."
            }
        }
    }

    /// Call from a background/control queue, never from an audio callback.
    /// The original Synth track remains unchanged. A returned patch may be
    /// loaded on that track using ProjectViewModel.loadStudioSampler.
    /// Optional directories let automated tests use isolated temporary files.
    public static func capture(patch: StudioSynthPatch, name: String,
                               options: Options = Options(),
                               sampleDirectory: URL? = nil,
                               packageDirectory: URL? = nil) throws -> Result {
        guard patch.validate(), options.isValid else {
            throw CaptureError.invalidOptions
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.invalidOptions }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-synth-capture-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: staging,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var takes: [StudioSamplerFactoryTake] = []
        for root in options.rootNotes.sorted() {
            for velocity in options.velocities.sorted() {
                let source = staging.appendingPathComponent(
                    "midi-\(root)-velocity-\(velocity).wav")
                try renderOne(patch: patch, note: root, velocity: velocity,
                              options: options, to: source)
                takes.append(StudioSamplerFactoryTake(
                    source: source, rootNote: root, velocity: velocity))
            }
        }

        let sampler = try StudioSamplerInstrumentFactory.assemble(
            takes, sampleDirectory: sampleDirectory)
        let metadata = StudioSamplerInstrumentPackage.Metadata(
            name: trimmed, category: "Synth Captures",
            tags: ["Studio Synth", "Native Multisample"])
        do {
            let package = try StudioSamplerInstrumentPackage.saveToLibrary(
                sampler, metadata: metadata, in: packageDirectory)
            return Result(patch: sampler, packageURL: package,
                          takeCount: takes.count)
        } catch {
            // The newly imported sources belong only to this failed capture;
            // remove them rather than leaving orphaned managed recordings.
            for zone in sampler.zones {
                if zone.managedFileName != nil {
                    try? FileManager.default.removeItem(at: zone.sampleURL)
                }
            }
            throw error
        }
    }

    private static func renderOne(patch: StudioSynthPatch,
                                  note: UInt8, velocity: UInt8,
                                  options: Options, to url: URL) throws {
        let rate = options.sampleRate
        let sound = try StudioSynthInstrument(sampleRate: rate, patch: patch)
        let engine = AVAudioEngine()
        try sound.attach(to: engine, destination: engine.mainMixerNode,
                         sampleRate: rate)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: 512) else {
            throw CaptureError.cannotPrepareAudio
        }
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 512)
        try engine.start()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }
        let writer = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)

        let noteFrames = Int(rate * options.sustainSeconds)
        let totalFrames = noteFrames + Int(rate * options.releaseSeconds)
        guard sound.noteOn(note, velocity: velocity) else {
            throw CaptureError.cannotPrepareAudio
        }
        var position = 0
        var peak: Float = 0
        while position < totalFrames {
            if position == noteFrames {
                guard sound.noteOff(note) else {
                    throw CaptureError.renderingFailed
                }
            }
            let edge = position < noteFrames ? noteFrames : totalFrames
            let count = AVAudioFrameCount(min(512, edge - position))
            guard count > 0,
                  try engine.renderOffline(count, to: buffer) == .success,
                  let channels = buffer.floatChannelData,
                  buffer.frameLength == count else {
                throw CaptureError.renderingFailed
            }
            for channel in 0..<2 {
                for i in 0..<Int(count) {
                    let sample = channels[channel][i]
                    guard sample.isFinite else { throw CaptureError.renderingFailed }
                    peak = max(peak, abs(sample))
                }
            }
            try writer.write(from: buffer)
            position += Int(count)
        }
        _ = sound.allNotesOff()
        guard peak > 0.000001 else { throw CaptureError.silentOutput }
    }
}
