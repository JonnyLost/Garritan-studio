import Foundation

/// Converts supported GigaStudio dimension cases into native Studio zones:
/// velocity splits, round-robin alternates and note-release triggers.
/// Unsupported dimensions are rejected without flattening other sample layers.
/// File I/O and conversion always happen off the audio thread.
public enum StudioSamplerGIGImporter {
    public struct Preview: Sendable {
        public let instrument: StudioSamplerGIGReader.Instrument
        public let regionCount: Int
        public let warnings: [String]
    }

    public struct Result: Sendable {
        public let instrument: StudioSamplerGIGReader.Instrument
        public let patch: StudioSamplerPatch
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case invalidInstrument
        case noPlayableRegions
        case tooManyZones
        case unsupportedDimensions(String)
        case missingSample(String)
        case unsupportedAudio(String)
        case invalidLoop(String)
        case truncatedSample
        case outputTooLarge

        public var errorDescription: String? {
            switch self {
            case .invalidInstrument: return "The selected GigaStudio instrument does not exist."
            case .noPlayableRegions: return "This GigaStudio instrument has no playable regions."
            case .tooManyZones: return "Studio currently supports up to 128 sampler zones."
            case .unsupportedDimensions(let instrument):
                return "\(instrument) uses a GigaStudio dimension Studio cannot reproduce yet (for example keyswitches, controller layers, or multi-sample layering)."
            case .missingSample(let instrument):
                return "A sample-pool reference is missing in \(instrument)."
            case .unsupportedAudio(let sample):
                return "The GigaStudio sample \(sample) is not uncompressed mono/stereo 16-bit PCM."
            case .invalidLoop(let sample): return "Invalid GigaStudio sample loop: \(sample)."
            case .truncatedSample: return "A GigaStudio PCM sample ended unexpectedly."
            case .outputTooLarge: return "A GigaStudio WAV sample exceeds the supported size."
            }
        }
    }

    private struct ZonePlan {
        let waveIndex: Int
        let parameters: StudioSamplerGIGReader.SampleParameters?
        let keyLow: UInt8
        let keyHigh: UInt8
        let velocityLow: UInt8
        let velocityHigh: UInt8
        let roundRobinIndex: UInt8?
        let isReleaseTrigger: Bool
    }

    private struct Plan {
        let instrument: StudioSamplerGIGReader.Instrument
        let zones: [ZonePlan]
        let warnings: [String]
    }

    public static func preview(_ url: URL, instrumentIndex: Int) throws -> Preview {
        let catalog = try StudioSamplerGIGReader.inspect(url)
        let plan = try plan(catalog, instrumentIndex: instrumentIndex)
        return Preview(instrument: plan.instrument, regionCount: plan.zones.count,
                       warnings: plan.warnings)
    }

    public static func importInstrument(_ url: URL, instrumentIndex: Int,
                                        into directory: URL? = nil) throws -> Result {
        let catalog = try StudioSamplerGIGReader.inspect(url)
        let plan = try plan(catalog, instrumentIndex: instrumentIndex)
        let destination = try directory ?? StudioSamplerSampleLibrary.libraryDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(
            ".gig-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var outputs: [Int: URL] = [:]
        var installed: [URL] = []
        do {
            for index in Set(plan.zones.map(\.waveIndex)).sorted() {
                let wave = catalog.waves[index]
                let output = destination.appendingPathComponent(
                    "\(UUID().uuidString)-GIG-\(index).wav")
                try extract(wave, from: reader,
                            to: staging.appendingPathComponent(output.lastPathComponent))
                outputs[index] = output
            }
            var zones: [StudioSamplerZone] = []
            for item in plan.zones {
                guard let output = outputs[item.waveIndex] else {
                    throw ImportError.truncatedSample
                }
                let wave = catalog.waves[item.waveIndex]
                let params = item.parameters ?? wave.parameters
                var zone = StudioSamplerZone(
                    sampleURL: output, rootNote: params?.root ?? 60,
                    lowestNote: item.keyLow, highestNote: item.keyHigh,
                    lowestVelocity: max(1, item.velocityLow),
                    highestVelocity: item.velocityHigh)
                zone.managedFileName = directory == nil
                    ? StudioSamplerSampleLibrary.managedName(for: output) : nil
                zone.roundRobinIndex = item.roundRobinIndex
                zone.isReleaseTrigger = item.isReleaseTrigger ? true : nil
                if !item.isReleaseTrigger,
                   let begin = params?.loopStart, let end = params?.loopEnd {
                    zone.loopStartFrame = begin
                    zone.loopEndFrame = end
                }
                guard zone.isValid else { throw ImportError.invalidLoop(wave.name) }
                zones.append(zone)
            }
            let patch = StudioSamplerPatch(zones: zones)
            guard patch.isValid else { throw ImportError.noPlayableRegions }
            // No committed output exists until extraction and mapping succeed.
            for output in outputs.values {
                try fm.moveItem(
                    at: staging.appendingPathComponent(output.lastPathComponent),
                    to: output)
                installed.append(output)
            }
            return Result(instrument: plan.instrument, patch: patch,
                          warnings: plan.warnings)
        } catch {
            for output in installed { try? fm.removeItem(at: output) }
            throw error
        }
    }

    private static func plan(_ catalog: StudioSamplerGIGReader.Catalog,
                             instrumentIndex: Int) throws -> Plan {
        guard catalog.instruments.indices.contains(instrumentIndex) else {
            throw ImportError.invalidInstrument
        }
        let instrument = catalog.instruments[instrumentIndex]
        guard !instrument.regions.isEmpty else { throw ImportError.noPlayableRegions }
        guard instrument.regions.count <= 128 else { throw ImportError.tooManyZones }

        var plans: [ZonePlan] = []
        var warnings = Set(catalog.warnings)
        for region in instrument.regions {
            for dimension in region.dimensions {
                switch dimension.type {
                case 0x82: // velocity split
                    break
                case 0x86: // note-on round robin, max eight Studio takes
                    guard dimension.zoneCount <= 8 else {
                        throw ImportError.unsupportedDimensions(instrument.name)
                    }
                case 0x84: // 0 = sustain, 1 = release trigger
                    guard dimension.zoneCount == 2 else {
                        throw ImportError.unsupportedDimensions(instrument.name)
                    }
                default:
                    // Keyboard keyswitch mappings, simultaneous layers,
                    // modwheel/controller dimensions, random selection and
                    // sample channels need separate interpretation.
                    throw ImportError.unsupportedDimensions(instrument.name)
                }
            }
            for (caseIndex, sampleCase) in region.cases.enumerated() {
                // An unassigned GIG case is a legitimate silent selection.
                guard let tableIndex = sampleCase.sampleTableIndex else { continue }
                guard Int(tableIndex) < catalog.sampleIndexToWave.count,
                      let waveIndex = catalog.sampleIndexToWave[Int(tableIndex)] else {
                    throw ImportError.missingSample(instrument.name)
                }
                var lowVelocity = max(1, Int(region.velocityLow))
                var highVelocity = Int(region.velocityHigh)
                var roundRobinIndex: UInt8?
                var isReleaseTrigger = false
                var shift = 0
                for dimension in region.dimensions {
                    let mask = dimension.zoneCount - 1
                    let caseValue = (caseIndex >> shift) & mask
                    shift += Int(dimension.bits)
                    switch dimension.type {
                    case 0x82:
                        // Regular GIG velocity splits partition MIDI 0...127.
                        // Custom GIG3 velocity boundaries need separate
                        // decoding; warn rather than claiming exact fidelity.
                        let lower = caseValue * 128 / dimension.zoneCount
                        let upper = (caseValue + 1) * 128 / dimension.zoneCount - 1
                        lowVelocity = max(lowVelocity, lower)
                        highVelocity = min(highVelocity, upper)
                    case 0x86:
                        roundRobinIndex = UInt8(caseValue)
                    case 0x84:
                        isReleaseTrigger = caseValue == 1
                    default:
                        // Checked above before any disk changes.
                        throw ImportError.unsupportedDimensions(instrument.name)
                    }
                }
                // Some GIG cases have zero-width or silent velocity ranges.
                if lowVelocity > highVelocity { continue }
                let wave = catalog.waves[waveIndex]
                guard wave.format == 1, (1...2).contains(wave.channels),
                      wave.bitsPerSample == 16,
                      wave.blockAlign == wave.channels * 2,
                      (8_000...384_000).contains(wave.sampleRate),
                      wave.dataSize >= UInt64(wave.blockAlign) * 2,
                      wave.dataSize % UInt64(wave.blockAlign) == 0 else {
                    throw ImportError.unsupportedAudio(wave.name)
                }
                let frames = wave.dataSize / UInt64(wave.blockAlign)
                guard frames <= 500_000_000,
                      wave.dataSize <= UInt64(UInt32.max - 36) else {
                    throw ImportError.outputTooLarge
                }
                let sampleParameters = sampleCase.parameters ??
                    region.parameters ?? wave.parameters
                if !isReleaseTrigger,
                   let begin = sampleParameters?.loopStart,
                   let end = sampleParameters?.loopEnd {
                    guard begin < end, end - begin >= 4, UInt64(end) <= frames else {
                        throw ImportError.invalidLoop(wave.name)
                    }
                }
                plans.append(ZonePlan(
                    waveIndex: waveIndex, parameters: sampleParameters,
                    keyLow: region.keyLow, keyHigh: region.keyHigh,
                    velocityLow: UInt8(lowVelocity),
                    velocityHigh: UInt8(highVelocity),
                    roundRobinIndex: roundRobinIndex,
                    isReleaseTrigger: isReleaseTrigger))
                guard plans.count <= 128 else { throw ImportError.tooManyZones }
            }
            for warning in region.warnings { warnings.insert(warning) }
            if region.dimensions.contains(where: { $0.type == 0x82 }) {
                warnings.insert("GigaStudio velocity splits use regular 128-step boundaries; custom split thresholds are not yet preserved.")
            }
            if region.dimensions.contains(where: { $0.type == 0x86 }) {
                warnings.insert("GigaStudio round-robin cases use Studio's native per-note take selection; exact counter scope may differ.")
            }
        }
        guard !plans.isEmpty else { throw ImportError.noPlayableRegions }
        warnings.insert("GigaStudio filters, crossfades, envelopes, scripts and controllers are not yet fully translated.")
        return Plan(instrument: instrument, zones: plans, warnings: warnings.sorted())
    }

    private static func extract(_ wave: StudioSamplerGIGReader.Wave,
                                from reader: FileHandle, to url: URL) throws {
        let byteCount = UInt32(wave.dataSize)
        let byteRate = UInt64(wave.sampleRate) * UInt64(wave.blockAlign)
        guard byteCount <= UInt32.max - 36,
              byteRate <= UInt64(UInt32.max),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ImportError.outputTooLarge
        }
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var header = Data()
        func word(_ value: UInt16) {
            header.append(UInt8(truncatingIfNeeded: value))
            header.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func dword(_ value: UInt32) {
            word(UInt16(truncatingIfNeeded: value))
            word(UInt16(truncatingIfNeeded: value >> 16))
        }
        header.append(contentsOf: "RIFF".utf8)
        dword(byteCount + 36)
        header.append(contentsOf: "WAVEfmt ".utf8)
        dword(16)
        word(1)
        word(wave.channels)
        dword(wave.sampleRate)
        dword(UInt32(byteRate))
        word(wave.blockAlign)
        word(16)
        header.append(contentsOf: "data".utf8)
        dword(byteCount)
        try writer.write(contentsOf: header)

        try reader.seek(toOffset: wave.dataOffset)
        var remaining = wave.dataSize
        while remaining > 0 {
            let amount = Int(min(remaining, 64 * 1024))
            guard let data = try reader.read(upToCount: amount),
                  !data.isEmpty else { throw ImportError.truncatedSample }
            try writer.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }
}
