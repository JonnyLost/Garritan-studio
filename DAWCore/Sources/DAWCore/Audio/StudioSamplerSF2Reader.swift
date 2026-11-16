import Foundation

/// Bounded, offline SoundFont 2 RIFF/pdta reader. This stage validates preset,
/// instrument, sample and generator records before audio extraction is enabled.
/// No external synthesizer, plugin or runtime dependency is required.
public enum StudioSamplerSF2Reader {
    public struct SampleHeader: Sendable, Equatable {
        public let name: String
        public let start: UInt32
        public let end: UInt32
        public let loopStart: UInt32
        public let loopEnd: UInt32
        public let sampleRate: UInt32
        public let originalPitch: UInt8
        public let pitchCorrection: Int8
        public let sampleLink: UInt16
        public let sampleType: UInt16
    }
    public struct Preset: Sendable, Equatable {
        public let name: String
        public let bank: UInt16
        public let program: UInt16
        public let bagIndex: UInt16
    }
    public struct Bag: Sendable, Equatable {
        public let generatorIndex: UInt16
        public let modulatorIndex: UInt16
    }
    public struct Generator: Sendable, Equatable {
        public let opcode: UInt16
        public let amount: UInt16
        public var signedAmount: Int { Int(Int16(bitPattern: amount)) }
    }
    public struct Instrument: Sendable, Equatable {
        public let name: String
        public let bagIndex: UInt16
    }
    public struct Catalog: Sendable {
        public let presets: [Preset]
        public let samples: [SampleHeader]
        public let pcm16Offset: Int
        public let pcm16ByteCount: Int
        public let presetBags: [Bag]
        public let presetGenerators: [Generator]
        public let instruments: [Instrument]
        public let instrumentBags: [Bag]
        public let instrumentGenerators: [Generator]
        public let warnings: [String]
    }
    public enum SF2Error: Error, LocalizedError {
        case invalidContainer
        case missingRequiredChunk(String)
        case invalidRecord(String)
        case tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidContainer: return "This is not a valid SoundFont 2 RIFF file."
            case .missingRequiredChunk(let name): return "SoundFont is missing \(name)."
            case .invalidRecord(let name): return "SoundFont has an invalid \(name) record."
            case .tooLarge: return "SoundFont exceeds the supported inspection size."
            }
        }
    }

    private struct Chunk {
        let offset: Int
        let size: Int
    }
    private static func u16(_ bytes: Data, _ i: Int) -> UInt16 {
        UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
    }
    private static func u32(_ bytes: Data, _ i: Int) -> UInt32 {
        UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) |
        (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    }
    private static func tag(_ bytes: Data, _ i: Int) -> String {
        String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
    }
    private static func name(_ bytes: Data, _ i: Int) -> String {
        let slice = bytes[i..<(i + 20)]
        return String(decoding: slice.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func chunks(_ bytes: Data, start: Int, end: Int) throws -> [(String, Chunk)] {
        var cursor = start
        var found: [(String, Chunk)] = []
        while cursor < end {
            guard end - cursor >= 8 else { throw SF2Error.invalidContainer }
            let size = Int(u32(bytes, cursor + 4))
            let payload = cursor + 8
            guard size <= end - payload else { throw SF2Error.invalidContainer }
            found.append((tag(bytes, cursor), Chunk(offset: payload, size: size)))
            let next = payload + size + (size & 1)
            guard next <= end else { throw SF2Error.invalidContainer }
            cursor = next
        }
        return found
    }

    /// Inspect preset and sample metadata; never modifies or extracts source audio.
    /// Sample extraction and generator interpretation belong to the next stage.
    public static func inspect(_ url: URL) throws -> Catalog {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 512 * 1024 * 1024
        else { throw SF2Error.tooLarge }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 12, tag(bytes, 0) == "RIFF",
              tag(bytes, 8) == "sfbk",
              Int(u32(bytes, 4)) == bytes.count - 8
        else { throw SF2Error.invalidContainer }
        let top = try chunks(bytes, start: 12, end: bytes.count)
        var pdta: [String: Chunk] = [:]
        var smpl: Chunk?
        for (kind, list) in top where kind == "LIST" && list.size >= 4 {
            let type = tag(bytes, list.offset)
            let entries = try chunks(bytes, start: list.offset + 4,
                                     end: list.offset + list.size)
            if type == "pdta" {
                for (name, entry) in entries {
                    guard pdta[name] == nil else { throw SF2Error.invalidRecord(name) }
                    pdta[name] = entry
                }
            } else if type == "sdta" {
                smpl = entries.first(where: { $0.0 == "smpl" })?.1
            }
        }
        guard let pcm = smpl, pcm.size >= 2, pcm.size % 2 == 0
        else { throw SF2Error.missingRequiredChunk("sdta/smpl") }
        let lengths = ["phdr": 38, "pbag": 4, "pmod": 10, "pgen": 4,
                       "inst": 22, "ibag": 4, "imod": 10, "igen": 4, "shdr": 46]
        for (key, stride) in lengths {
            guard let chunk = pdta[key], chunk.size >= stride,
                  chunk.size % stride == 0 else {
                throw SF2Error.missingRequiredChunk("pdta/\(key)")
            }
        }
        func readBags(_ chunk: Chunk) -> [Bag] {
            (0..<(chunk.size / 4)).map { index in
                let at = chunk.offset + index * 4
                return Bag(generatorIndex: u16(bytes, at),
                           modulatorIndex: u16(bytes, at + 2))
            }
        }
        func readGenerators(_ chunk: Chunk) -> [Generator] {
            (0..<(chunk.size / 4)).map { index in
                let at = chunk.offset + index * 4
                return Generator(opcode: u16(bytes, at), amount: u16(bytes, at + 2))
            }
        }
        let presetBags = readBags(pdta["pbag"]!)
        let instrumentBags = readBags(pdta["ibag"]!)
        let presetGenerators = readGenerators(pdta["pgen"]!)
        let instrumentGenerators = readGenerators(pdta["igen"]!)
        func validateBags(_ bags: [Bag], generatorCount: Int,
                          modulatorCount: Int, label: String) throws {
            guard bags.count >= 2 else { throw SF2Error.invalidRecord(label) }
            for (index, bag) in bags.enumerated() {
                guard Int(bag.generatorIndex) <= generatorCount,
                      Int(bag.modulatorIndex) <= modulatorCount,
                      index == 0 || (bag.generatorIndex >= bags[index - 1].generatorIndex &&
                                     bag.modulatorIndex >= bags[index - 1].modulatorIndex) else {
                    throw SF2Error.invalidRecord(label)
                }
            }
        }
        try validateBags(presetBags, generatorCount: presetGenerators.count,
                         modulatorCount: pdta["pmod"]!.size / 10, label: "preset bag")
        try validateBags(instrumentBags, generatorCount: instrumentGenerators.count,
                         modulatorCount: pdta["imod"]!.size / 10, label: "instrument bag")
        let instChunk = pdta["inst"]!
        guard instChunk.size >= 44 else { throw SF2Error.invalidRecord("instrument table") }
        let instruments = (0..<(instChunk.size / 22 - 1)).map { index in
            let at = instChunk.offset + index * 22
            return Instrument(name: name(bytes, at), bagIndex: u16(bytes, at + 20))
        }
        var lastInstBag: UInt16 = 0
        for instrument in instruments {
            guard instrument.bagIndex >= lastInstBag,
                  Int(instrument.bagIndex) < instrumentBags.count - 1 else {
                throw SF2Error.invalidRecord("instrument bag index")
            }
            lastInstBag = instrument.bagIndex
        }
        let instrumentTerminal = u16(bytes, instChunk.offset + instChunk.size - 2)
        guard instrumentTerminal >= lastInstBag,
              Int(instrumentTerminal) < instrumentBags.count else {
            throw SF2Error.invalidRecord("instrument terminal")
        }
        let presetChunk = pdta["phdr"]!
        let sampleChunk = pdta["shdr"]!
        let presetCount = presetChunk.size / 38 - 1
        let sampleCount = sampleChunk.size / 46 - 1
        guard presetCount <= 65_536, sampleCount <= 65_536
        else { throw SF2Error.tooLarge }
        var presets: [Preset] = []
        var previousPresetBag: UInt16 = 0
        for index in 0..<presetCount {
            let at = presetChunk.offset + index * 38
            let bag = u16(bytes, at + 24)
            guard Int(bag) < presetBags.count - 1, bag >= previousPresetBag else {
                throw SF2Error.invalidRecord("preset bag index")
            }
            previousPresetBag = bag
            presets.append(Preset(name: name(bytes, at), bank: u16(bytes, at + 22),
                                  program: u16(bytes, at + 20), bagIndex: bag))
        }
        let presetTerminal = u16(bytes, presetChunk.offset + presetChunk.size - 14)
        guard presetTerminal >= previousPresetBag,
              Int(presetTerminal) < presetBags.count else {
            throw SF2Error.invalidRecord("preset terminal")
        }
        var samples: [SampleHeader] = []
        let frames = UInt32(pcm.size / 2)
        for index in 0..<sampleCount {
            let at = sampleChunk.offset + index * 46
            let start = u32(bytes, at + 20)
            let end = u32(bytes, at + 24)
            let loopStart = u32(bytes, at + 28)
            let loopEnd = u32(bytes, at + 32)
            let rate = u32(bytes, at + 36)
            guard start < end, end <= frames, rate > 0,
                  loopStart >= start, loopStart <= loopEnd, loopEnd <= end else {
                throw SF2Error.invalidRecord("sample header")
            }
            samples.append(SampleHeader(
                name: name(bytes, at), start: start, end: end,
                loopStart: loopStart, loopEnd: loopEnd, sampleRate: rate,
                originalPitch: bytes[at + 40],
                pitchCorrection: Int8(bitPattern: bytes[at + 41]),
                sampleLink: u16(bytes, at + 42),
                sampleType: u16(bytes, at + 44)))
        }
        return Catalog(presets: presets, samples: samples,
                       pcm16Offset: pcm.offset, pcm16ByteCount: pcm.size,
                       presetBags: presetBags, presetGenerators: presetGenerators,
                       instruments: instruments, instrumentBags: instrumentBags,
                       instrumentGenerators: instrumentGenerators,
                       warnings: ["SoundFont modulators and built-in effects are not yet translated."])
    }
}
