import Foundation
import AVFoundation

/// A small, entirely original collection of sound-design starting points.
/// These are synthesized sample recordings, not simulations of a captured
/// violin/brass section. Instrument Factory can edit and resave each of them.
public enum StudioSamplerFactoryStarterLibrary {
    public enum Voice: String, CaseIterable, Sendable {
        case stringSketch = "Studio String Sketch"
        case airyPad = "Studio Air Pad"
        case glassKeys = "Studio Glass Keys"
        case pluckedTone = "Studio Plucked Tone"

        public var category: String {
            switch self {
            case .stringSketch: return "Synthetic Strings"
            case .airyPad: return "Pads"
            case .glassKeys: return "Keys"
            case .pluckedTone: return "Plucked"
            }
        }

        public var isSustained: Bool {
            self == .stringSketch || self == .airyPad
        }
    }

    public enum FactoryError: Error, LocalizedError {
        case cannotCreateBuffer
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .cannotCreateBuffer: return "Studio could not generate the starter sample."
            case .cancelled: return "Starter instrument creation was cancelled."
            }
        }
    }

    /// Idempotent installer. The four instruments are authored by our own
    /// algorithms on demand, so no sample waveforms ship in the application.
    /// Committed packages are independent of the temporary rendered PCM.
    public static func install(in directory: URL? = nil) throws -> [URL] {
        let folder = try directory ??
            StudioSamplerInstrumentPackage.libraryDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = try StudioSamplerInstrumentPackage.listLibrary(in: folder)
        let availableNames = Set(existing
            .filter { $0.metadata.tags.contains("Studio Original") }
            .map { $0.metadata.name })
        let temporary = fm.temporaryDirectory.appendingPathComponent(
            "StudioFactory-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        var created: [URL] = []
        do {
            for voice in Voice.allCases where !availableNames.contains(voice.rawValue) {
                if Task<Never, Never>.isCancelled { throw FactoryError.cancelled }
                let files = try renderSamples(for: voice, in: temporary)
                var patch = try StudioSamplerMappingBuilder.makePatch(urls: files)
                patch.instrumentKind = voice == .stringSketch ? .soloViolin :
                    voice == .airyPad ? .choirAndTextures : .general
                patch.envelope = StudioSamplerEnvelope(
                    attackSeconds: voice.isSustained ? 0.06 : 0.0015,
                    decaySeconds: voice.isSustained ? 0.12 : 0.15,
                    sustainLevel: voice.isSustained ? 0.85 : 0.65,
                    releaseSeconds: voice.isSustained ? 0.3 : 0.12
                )
                if voice.isSustained {
                    for index in patch.zones.indices {
                        patch.zones[index].loopStartFrame = 22_050
                        patch.zones[index].loopEndFrame = 88_200
                        patch.zones[index].loopCrossfadeFrames = 512
                    }
                }
                guard patch.isValid else { throw FactoryError.cannotCreateBuffer }
                let metadata = StudioSamplerInstrumentPackage.Metadata(
                    name: voice.rawValue,
                    category: voice.category,
                    tags: ["Studio Original", "Editable", "Synthetic"])
                let url = try StudioSamplerInstrumentPackage.saveToLibrary(
                    patch, metadata: metadata, in: folder)
                created.append(url)
            }
        } catch {
            for url in created {
                try? StudioSamplerInstrumentPackage.removeFromLibrary(url, in: folder)
            }
            throw error
        }
        return created
    }

    private static func renderSamples(for voice: Voice,
                                      in directory: URL) throws -> [URL] {
        let rate = 44_100.0
        let duration = voice.isSustained ? 2.5 : 1.8
        let frames = Int(rate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0]
        else { throw FactoryError.cannotCreateBuffer }
        buffer.frameLength = AVAudioFrameCount(frames)
        var files: [URL] = []
        let noteNames = [(48, "C3"), (60, "C4"), (72, "C5"), (84, "C6")]
        for (note, name) in noteNames {
            if Task<Never, Never>.isCancelled { throw FactoryError.cancelled }
            let frequency = 440.0 * pow(2, Double(note - 69) / 12.0)
            for i in 0..<frames {
                let t = Double(i) / rate
                let envelope: Double
                switch voice {
                case .stringSketch:
                    envelope = (1 - exp(-t * 60)) *
                        (0.87 + 0.13 * exp(-t * 1.8))
                case .airyPad:
                    envelope = (1 - exp(-t * 8)) *
                        (0.86 + 0.14 * sin(2 * .pi * 0.18 * t))
                case .glassKeys:
                    envelope = (1 - exp(-t * 450)) * exp(-t * 1.6)
                case .pluckedTone:
                    envelope = (1 - exp(-t * 700)) * exp(-t * 2.0)
                }
                let angle = 2 * Double.pi * frequency * t
                var wave = 0.0
                switch voice {
                case .stringSketch:
                    for harmonic in 1...10 {
                        wave += sin(angle * Double(harmonic) +
                            sin(2 * .pi * 5.3 * t) * 0.008 * Double(harmonic)) /
                            pow(Double(harmonic), 1.30)
                    }
                case .airyPad:
                    wave = 0.60 * sin(angle) +
                        0.23 * sin(angle * 2.005) +
                        0.15 * sin(angle * 3.01) +
                        0.07 * sin(angle * 4.004)
                case .glassKeys:
                    wave = sin(angle) * 0.65 +
                        sin(angle * 2.76) * 0.23 +
                        sin(angle * 5.40) * 0.12
                case .pluckedTone:
                    for harmonic in 1...8 {
                        wave += sin(angle * Double(harmonic)) *
                            exp(-t * Double(harmonic) * 0.8) /
                            Double(harmonic)
                    }
                }
                let release = min(1.0, Double(frames - i) / 220.0)
                channel[i] = Float(max(-0.90, min(0.90,
                    wave * envelope * release * 0.30)))
            }
            let url = directory.appendingPathComponent(
                "\(voice.rawValue.replacingOccurrences(of: " ", with: ""))_\(name).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            try autoreleasepool {
                let output = try AVAudioFile(forWriting: url, settings: settings,
                                             commonFormat: .pcmFormatFloat32,
                                             interleaved: false)
                try output.write(from: buffer)
            }
            files.append(url)
        }
        return files
    }
}
