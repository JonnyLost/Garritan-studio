import Foundation

/// Converts one SoundFont 2 preset into Studio's native, editable sample zones.
/// Runs offline; no SoundFont synthesizer or third-party plugin is loaded.
public enum StudioSamplerSF2Importer {
    public struct Preview: Sendable {
        public let preset: StudioSamplerSF2Reader.Preset
        public let zoneCount: Int
        public let warnings: [String]
    }

    public struct Result: Sendable {
        public let patch: StudioSamplerPatch
        public let preset: StudioSamplerSF2Reader.Preset
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case invalidPreset
        case invalidMapping(String)
        case noPlayableZones
        case tooManyZones
        case unsupportedSample(String)
        case invalidAudio
        case damagedSource
        public var errorDescription: String? {
            switch self {
            case .invalidPreset: return "The SoundFont preset index does not exist."
            case .invalidMapping(let reason): return "Invalid SoundFont instrument mapping: \(reason)"
            case .noPlayableZones: return "This SoundFont preset has no supported sample zones."
            case .tooManyZones: return "Studio supports at most 128 sample zones per instrument."
            case .unsupportedSample(let name): return "Unsupported SoundFont sample: \(name)"
            case .invalidAudio: return "SoundFont PCM sample data is invalid or exceeds WAV limits."
            case .damagedSource: return "The SoundFont sample data ended unexpectedly."
            }
        }
    }

    private typealias Generators = [UInt16: StudioSamplerSF2Reader.Generator]
    private struct ZonePlan {
        var sampleID: Int
        var root: UInt8
        var lowKey: UInt8
        var highKey: UInt8
        var lowVelocity: UInt8
        var highVelocity: UInt8
        var trimStart: UInt32?
        var trimEnd: UInt32?
        var loopStart: UInt32?
        var loopEnd: UInt32?
    }
    private struct Plan {
        var preset: StudioSamplerSF2Reader.Preset
        var zones: [ZonePlan]
        var warnings: [String]
    }
    private struct AudioPair {
        let left: StudioSamplerSF2Reader.SampleHeader
        let right: StudioSamplerSF2Reader.SampleHeader?
        let canonicalIndex: Int
    }

    public static func preview(_ url: URL, presetIndex: Int) throws -> Preview {
        let catalog = try StudioSamplerSF2Reader.inspect(url)
        let plan = try makePlan(catalog, presetIndex: presetIndex)
        return Preview(preset: plan.preset, zoneCount: plan.zones.count,
                       warnings: plan.warnings)
    }

    /// Extract only samples used by the selected preset. All extracted WAV files
    /// are staged first; on any failure, newly installed files are rolled back.
    /// The source SF2 is never modified.
    public static func importInstrument(_ url: URL,
                                        presetIndex: Int,
                                        into directory: URL? = nil) throws -> Result {
        let catalog = try StudioSamplerSF2Reader.inspect(url)
        let plan = try makePlan(catalog, presetIndex: presetIndex)
        let destination = try directory ?? StudioSamplerSampleLibrary.libraryDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(
            ".sf2-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }

        var outputs: [Int: URL] = [:]
        var canonical: [Int: URL] = [:]
        var installed: [URL] = []
        do {
            for id in Set(plan.zones.map(\.sampleID)).sorted() {
                let pair = try audioPair(for: id, in: catalog)
                let output: URL
                if let existing = canonical[pair.canonicalIndex] {
                    output = existing
                } else {
                    let filename = "\(UUID().uuidString)-SF2-\(pair.canonicalIndex).wav"
                    let staged = staging.appendingPathComponent(filename)
                    try writeWAV(pair, source: reader, pcmOffset: catalog.pcm16Offset,
                                 to: staged)
                    output = destination.appendingPathComponent(filename)
                    canonical[pair.canonicalIndex] = output
                }
                outputs[id] = output
            }
            var zones: [StudioSamplerZone] = []
            for planned in plan.zones {
                guard let output = outputs[planned.sampleID] else {
                    throw ImportError.invalidAudio
                }
                var zone = StudioSamplerZone(
                    sampleURL: output, rootNote: planned.root,
                    lowestNote: planned.lowKey, highestNote: planned.highKey,
                    lowestVelocity: planned.lowVelocity,
                    highestVelocity: planned.highVelocity)
                zone.trimStartFrame = planned.trimStart
                zone.trimEndFrame = planned.trimEnd
                zone.loopStartFrame = planned.loopStart
                zone.loopEndFrame = planned.loopEnd
                zone.managedFileName = StudioSamplerSampleLibrary.managedName(
                    for: output, in: directory)
                guard zone.isValid else { throw ImportError.invalidAudio }
                zones.append(zone)
            }
            let patch = StudioSamplerPatch(zones: zones)
            guard patch.isValid else { throw ImportError.invalidAudio }

            // Commit only after all samples and mappings have been validated.
            for output in canonical.values {
                let staged = staging.appendingPathComponent(output.lastPathComponent)
                try fm.moveItem(at: staged, to: output)
                installed.append(output)
            }
            return Result(patch: patch, preset: plan.preset, warnings: plan.warnings)
        } catch {
            for file in installed { try? fm.removeItem(at: file) }
            throw error
        }
    }

    private static func generators(_ bags: [StudioSamplerSF2Reader.Bag],
                                   _ entries: [StudioSamplerSF2Reader.Generator],
                                   at index: Int) throws -> Generators {
        guard index >= 0, index + 1 < bags.count else {
            throw ImportError.invalidMapping("bag index")
        }
        let start = Int(bags[index].generatorIndex)
        let end = Int(bags[index + 1].generatorIndex)
        guard start <= end, end <= entries.count else {
            throw ImportError.invalidMapping("generator index")
        }
        var values: Generators = [:]
        for entry in entries[start..<end] { values[entry.opcode] = entry }
        return values
    }

    private static func merged(_ global: Generators, _ local: Generators) -> Generators {
        var combined = global
        combined.merge(local) { _, local in local }
        return combined
    }

    private static func midiRange(_ generators: Generators, opcode: UInt16) throws -> ClosedRange<Int> {
        let raw = generators[opcode]?.amount ?? 0x7f00
        let low = Int(raw & 0xff)
        let high = Int(raw >> 8)
        guard low <= high, high <= 127 else {
            throw ImportError.invalidMapping("invalid key/velocity range")
        }
        return low...high
    }

    private static func translatedWarning(_ generators: Generators, warnings: inout Set<String>) {
        let used: Set<UInt16> = [0, 1, 2, 3, 4, 12, 41, 43, 44, 45,
                                 50, 51, 53, 54, 58]
        for opcode in generators.keys where !used.contains(opcode) {
            warnings.insert("SoundFont generator \(opcode) cannot be reproduced by the current sampler.")
        }
    }

    private static func offset(_ generators: Generators, small: UInt16,
                               coarse: UInt16? = nil) -> Int64 {
        let fine = Int64(generators[small]?.signedAmount ?? 0)
        let large = coarse.map { Int64(generators[$0]?.signedAmount ?? 0) } ?? 0
        return fine + large * 32_768
    }

    private static func makePlan(_ catalog: StudioSamplerSF2Reader.Catalog,
                                 presetIndex: Int) throws -> Plan {
        guard catalog.presets.indices.contains(presetIndex) else {
            throw ImportError.invalidPreset
        }
        let preset = catalog.presets[presetIndex]
        let start = Int(preset.bagIndex)
        let end = presetIndex + 1 < catalog.presets.count
            ? Int(catalog.presets[presetIndex + 1].bagIndex)
            : catalog.presetBags.count - 1
        guard start <= end, end < catalog.presetBags.count else {
            throw ImportError.invalidMapping("preset bag span")
        }
        var warnings = Set(catalog.warnings)
        var zones: [ZonePlan] = []
        var presetGlobal: Generators = [:]
        for bagIndex in start..<end {
            let local = try generators(catalog.presetBags,
                                       catalog.presetGenerators, at: bagIndex)
            if local[41] == nil {
                if bagIndex == start { presetGlobal = local }
                else { warnings.insert("A preset zone without an instrument was ignored.") }
                continue
            }
            let presetGenerators = merged(presetGlobal, local)
            translatedWarning(presetGenerators, warnings: &warnings)
            let instrumentID = Int(local[41]!.amount)
            guard catalog.instruments.indices.contains(instrumentID) else {
                throw ImportError.invalidMapping("instrument reference")
            }
            let instrument = catalog.instruments[instrumentID]
            let instStart = Int(instrument.bagIndex)
            let instEnd = instrumentID + 1 < catalog.instruments.count
                ? Int(catalog.instruments[instrumentID + 1].bagIndex)
                : catalog.instrumentBags.count - 1
            guard instStart <= instEnd, instEnd < catalog.instrumentBags.count else {
                throw ImportError.invalidMapping("instrument bag span")
            }
            var instrumentGlobal: Generators = [:]
            for instBag in instStart..<instEnd {
                let localInst = try generators(catalog.instrumentBags,
                                               catalog.instrumentGenerators, at: instBag)
                if localInst[53] == nil {
                    if instBag == instStart { instrumentGlobal = localInst }
                    else { warnings.insert("An instrument zone without a sample was ignored.") }
                    continue
                }
                let instGen = merged(instrumentGlobal, localInst)
                translatedWarning(instGen, warnings: &warnings)
                let presetKey = try midiRange(presetGenerators, opcode: 43)
                let presetVelocity = try midiRange(presetGenerators, opcode: 44)
                let instKey = try midiRange(instGen, opcode: 43)
                let instVelocity = try midiRange(instGen, opcode: 44)
                let low = max(presetKey.lowerBound, instKey.lowerBound)
                let high = min(presetKey.upperBound, instKey.upperBound)
                let lowVel = max(1, presetVelocity.lowerBound, instVelocity.lowerBound)
                let highVel = min(presetVelocity.upperBound, instVelocity.upperBound)
                if low > high || lowVel > highVel { continue }
                let sampleID = Int(localInst[53]!.amount)
                guard catalog.samples.indices.contains(sampleID) else {
                    throw ImportError.invalidMapping("sample reference")
                }
                let sample = catalog.samples[sampleID]
                _ = try audioPair(for: sampleID, in: catalog)
                let baseRoot = (instGen[58]?.amount).flatMap {
                    $0 <= 127 ? Int($0) : nil
                } ?? (sample.originalPitch <= 127 ? Int(sample.originalPitch) : 60)
                let coarseTune = (instGen[51]?.signedAmount ?? 0) +
                                 (presetGenerators[51]?.signedAmount ?? 0)
                let root = max(0, min(127, baseRoot - coarseTune))
                if root != baseRoot - coarseTune {
                    warnings.insert("A tuned root note was clamped to the MIDI range.")
                }
                if sample.pitchCorrection != 0 ||
                    instGen[52] != nil || presetGenerators[52] != nil {
                    warnings.insert("Fine tuning in cents is not yet preserved.")
                }
                let sampleStart = Int64(sample.start)
                let sampleEnd = Int64(sample.end)
                let first = sampleStart + offset(instGen, small: 0, coarse: 4)
                let last = sampleEnd + offset(instGen, small: 1, coarse: 12)
                guard first >= sampleStart, last <= sampleEnd, last - first >= 2 else {
                    throw ImportError.invalidMapping("sample trim offsets")
                }
                let relativeStart = first - sampleStart
                let relativeEnd = last - sampleStart
                let loopMode = Int(instGen[54]?.amount ?? 0) & 3
                var loopStart: UInt32?
                var loopEnd: UInt32?
                if loopMode == 1 || loopMode == 3 {
                    let begin = Int64(sample.loopStart) +
                        offset(instGen, small: 2, coarse: 45)
                    let finish = Int64(sample.loopEnd) +
                        offset(instGen, small: 3, coarse: 50)
                    if begin >= first && finish <= last && finish - begin >= 4 {
                        loopStart = UInt32(begin - sampleStart)
                        loopEnd = UInt32(finish - sampleStart)
                    } else {
                        warnings.insert("An invalid sample loop was disabled.")
                    }
                }
                zones.append(ZonePlan(
                    sampleID: sampleID, root: UInt8(root),
                    lowKey: UInt8(low), highKey: UInt8(high),
                    lowVelocity: UInt8(lowVel), highVelocity: UInt8(highVel),
                    trimStart: relativeStart == 0 ? nil : UInt32(relativeStart),
                    trimEnd: relativeEnd == sampleEnd - sampleStart ? nil : UInt32(relativeEnd),
                    loopStart: loopStart, loopEnd: loopEnd))
                if zones.count > 128 { throw ImportError.tooManyZones }
            }
        }
        guard !zones.isEmpty else { throw ImportError.noPlayableZones }
        return Plan(preset: preset, zones: zones, warnings: warnings.sorted())
    }

    private static func audioPair(for sampleID: Int,
                                  in catalog: StudioSamplerSF2Reader.Catalog) throws -> AudioPair {
        guard catalog.samples.indices.contains(sampleID) else {
            throw ImportError.invalidMapping("sample index")
        }
        let sample = catalog.samples[sampleID]
        guard sample.sampleType & 0x8000 == 0 else {
            throw ImportError.unsupportedSample("ROM samples are unavailable: \(sample.name)")
        }
        if sample.sampleType == 1 {
            return AudioPair(left: sample, right: nil, canonicalIndex: sampleID)
        }
        guard sample.sampleType == 2 || sample.sampleType == 4,
              catalog.samples.indices.contains(Int(sample.sampleLink)) else {
            throw ImportError.unsupportedSample(sample.name)
        }
        let partnerIndex = Int(sample.sampleLink)
        let partner = catalog.samples[partnerIndex]
        let leftIndex = sample.sampleType == 4 ? sampleID : partnerIndex
        let left = sample.sampleType == 4 ? sample : partner
        let right = sample.sampleType == 2 ? sample : partner
        guard left.sampleType == 4, right.sampleType == 2,
              Int(partner.sampleLink) == sampleID,
              left.end - left.start == right.end - right.start,
              left.sampleRate == right.sampleRate else {
            throw ImportError.unsupportedSample("invalid stereo link: \(sample.name)")
        }
        return AudioPair(left: left, right: right, canonicalIndex: leftIndex)
    }

    private static func readPCM(_ handle: FileHandle, at byteOffset: UInt64,
                                byteCount: Int) throws -> Data {
        try handle.seek(toOffset: byteOffset)
        var data = Data()
        while data.count < byteCount {
            guard let next = try handle.read(upToCount: byteCount - data.count),
                  !next.isEmpty else { throw ImportError.damagedSource }
            data.append(next)
        }
        return data
    }

    private static func header(sampleRate: UInt32, channels: UInt16,
                               frames: Int) throws -> Data {
        let bytes = Int64(frames) * Int64(channels) * 2
        let byteRate = UInt64(sampleRate) * UInt64(channels) * 2
        guard frames >= 2, bytes <= Int64(UInt32.max - 36),
              byteRate <= UInt64(UInt32.max) else {
            throw ImportError.invalidAudio
        }
        var data = Data()
        func word(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func dword(_ value: UInt32) {
            word(UInt16(truncatingIfNeeded: value))
            word(UInt16(truncatingIfNeeded: value >> 16))
        }
        data.append(contentsOf: "RIFF".utf8)
        dword(UInt32(bytes + 36))
        data.append(contentsOf: "WAVEfmt ".utf8)
        dword(16)
        word(1) // signed integer PCM
        word(channels)
        dword(sampleRate)
        dword(UInt32(byteRate))
        word(channels * 2)
        word(16)
        data.append(contentsOf: "data".utf8)
        dword(UInt32(bytes))
        return data
    }

    private static func writeWAV(_ pair: AudioPair, source: FileHandle,
                                 pcmOffset: Int, to destination: URL) throws {
        let frames = Int(pair.left.end - pair.left.start)
        let channelCount: UInt16 = pair.right == nil ? 1 : 2
        let wavHeader = try header(sampleRate: pair.left.sampleRate,
                                   channels: channelCount, frames: frames)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ImportError.invalidAudio
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        try writer.write(contentsOf: wavHeader)
        var processed = 0
        while processed < frames {
            let count = min(32_768, frames - processed)
            let leftOffset = UInt64(pcmOffset) +
                (UInt64(pair.left.start) + UInt64(processed)) * 2
            let left = try readPCM(source, at: leftOffset, byteCount: count * 2)
            if let rightSample = pair.right {
                let rightOffset = UInt64(pcmOffset) +
                    (UInt64(rightSample.start) + UInt64(processed)) * 2
                let right = try readPCM(source, at: rightOffset, byteCount: count * 2)
                var interleaved = Data(count: count * 4)
                interleaved.withUnsafeMutableBytes { destination in
                    let output = destination.bindMemory(to: UInt8.self)
                    left.withUnsafeBytes { leftBuffer in
                        right.withUnsafeBytes { rightBuffer in
                            let l = leftBuffer.bindMemory(to: UInt8.self)
                            let r = rightBuffer.bindMemory(to: UInt8.self)
                            for i in 0..<count {
                                output[i * 4] = l[i * 2]
                                output[i * 4 + 1] = l[i * 2 + 1]
                                output[i * 4 + 2] = r[i * 2]
                                output[i * 4 + 3] = r[i * 2 + 1]
                            }
                        }
                    }
                }
                try writer.write(contentsOf: interleaved)
            } else {
                try writer.write(contentsOf: left)
            }
            processed += count
        }
    }
}
