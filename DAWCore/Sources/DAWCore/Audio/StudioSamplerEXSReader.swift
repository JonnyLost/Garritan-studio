import Foundation

/// Bounded, offline EXS24 / Logic Sampler instrument inspection.
///
/// This reader does not invoke Logic, Audio Units, conversion plugins, or any
/// third-party EXS parser. It handles the little-endian TBOS/JBOS block format
/// documented for legacy EXS24 instruments. Rich group routing and newer Logic
/// features are exposed for explicit rejection by the importer.
public enum StudioSamplerEXSReader {
    public struct Zone: Sendable {
        public let name: String
        public let sampleIndex: Int
        public let groupIndex: Int?
        public let rootNote: UInt8
        public let keyLow: UInt8
        public let keyHigh: UInt8
        public let velocityLow: UInt8
        public let velocityHigh: UInt8
        public let flags: UInt8
        public let fineTuning: Int8
        public let coarseTuning: Int8
        public let pan: Int8
        public let gain: Int8
        public let trimStart: UInt32
        public let trimEnd: UInt32
        public let loopStart: UInt32
        public let loopEnd: UInt32
        public let loopCrossfadeMilliseconds: UInt32
        public let loopFlags: UInt8
        public let loopDirection: UInt8
    }

    public struct Group: Sendable {
        public let index: Int
        public let name: String
        public let mute: Bool
        public let velocityLow: UInt8
        public let velocityHigh: UInt8
        public let releaseTrigger: Bool
        public let roundRobinPosition: Int32
        public let enableByType: UInt8
        public let velocityCrossfade: Int8
        public let keyCrossfade: Int8
    }

    public struct Sample: Sendable {
        public let index: Int
        public let name: String
        /// The path as stored in the EXS file, not a resolved filesystem URL.
        public let directoryOrPath: String
        public let fileName: String
        public let sampleRate: UInt32
        public let sampleLength: UInt32
    }

    public struct Catalog: Sendable {
        public let name: String
        public let zones: [Zone]
        public let groups: [Int: Group]
        public let samples: [Int: Sample]
        public let warnings: [String]
    }

    public enum EXSError: Error, LocalizedError {
        case invalidContainer
        case unsupportedEndianness
        case damagedBlock
        case missingInstrument
        case noZones
        case noSamples
        case tooManyBlocks
        case invalidMapping(String)

        public var errorDescription: String? {
            switch self {
            case .invalidContainer: return "Not a supported binary EXS24 instrument."
            case .unsupportedEndianness:
                return "Legacy big-endian EXS24 instruments are not yet supported."
            case .damagedBlock: return "The EXS24 file contains an incomplete or invalid block."
            case .missingInstrument: return "The EXS24 instrument header is missing."
            case .noZones: return "The EXS24 instrument has no sample zones."
            case .noSamples: return "The EXS24 instrument has no sample references."
            case .tooManyBlocks: return "The EXS24 instrument exceeds Studio's inspection limits."
            case .invalidMapping(let reason): return "Invalid EXS24 mapping: \(reason)"
            }
        }
    }

    private static func word(_ bytes: Data, _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    private static func dword(_ bytes: Data, _ at: Int) -> UInt32 {
        UInt32(word(bytes, at)) | UInt32(word(bytes, at + 2)) << 16
    }
    private static func signed(_ byte: UInt8) -> Int8 {
        Int8(bitPattern: byte)
    }
    private static func cString(_ bytes: Data, at: Int, size: Int) -> String {
        let body = bytes[at..<(at + size)].prefix(while: { $0 != 0 })
        return String(data: Data(body), encoding: .utf8)
            ?? String(data: Data(body), encoding: .windowsCP1252)
            ?? String(decoding: body, as: UTF8.self)
    }

    /// Parse one selected .exs file; the sample file system is not touched.
    /// The caller must resolve and validate audio before importing.
    public static func inspect(_ url: URL) throws -> Catalog {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attrs[.size] as? NSNumber,
              bytes.uint64Value <= 16 * 1024 * 1024 else {
            throw EXSError.tooManyBlocks
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 84 else { throw EXSError.invalidContainer }

        var offset = 0
        var instrumentName: String?
        var zones: [Zone] = []
        var groups: [Int: Group] = [:]
        var samples: [Int: Sample] = [:]
        var warnings = Set<String>()
        var blockCount = 0

        while offset < data.count {
            guard data.count - offset >= 84 else { throw EXSError.damagedBlock }
            guard data[offset] == 1, data[offset + 1] == 1,
                  data[offset + 2] == 0 else {
                if data[offset + 16] == 83 { throw EXSError.unsupportedEndianness }
                throw EXSError.invalidContainer
            }
            let kind = data[offset + 3]
            guard kind <= 4 || (0x40...0x44).contains(kind) else {
                throw EXSError.invalidContainer
            }
            let signature = cString(data, at: offset + 16, size: 4)
            guard signature == "TBOS" || signature == "JBOS" else {
                throw EXSError.invalidContainer
            }
            // EXS24 stores a 15-bit block length in header bytes 4–5.
            // The flag on byte 5 is not part of the length, including for
            // newer TBOS variants. Bytes 6–7 are reserved.
            let length = Int(data[offset + 4]) +
                (Int(data[offset + 5] & 0x7f) << 8)
            guard length > 0, length <= data.count - offset - 84 else {
                throw EXSError.damagedBlock
            }
            let body = offset + 84
            let name = cString(data, at: offset + 20, size: 64)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let index = Int(dword(data, offset + 8))
            switch Int(kind & 0x0f) {
            case 0:
                guard length >= 16 else { throw EXSError.damagedBlock }
                if instrumentName == nil {
                    instrumentName = name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
                } else {
                    warnings.insert("Multiple EXS instrument headers were detected.")
                }
            case 1:
                guard length >= 96 else { throw EXSError.damagedBlock }
                let root = data[body + 1]
                let low = data[body + 6]
                let high = data[body + 7]
                let velLow = data[body + 9]
                let velHigh = data[body + 10]
                guard root <= 127, low <= high, high <= 127,
                      velLow <= velHigh, velHigh <= 127 else {
                    throw EXSError.invalidMapping("invalid zone key or velocity range")
                }
                let rawGroup = dword(data, body + 88)
                let rawSample = dword(data, body + 92)
                guard rawSample <= 1_000_000 else {
                    throw EXSError.invalidMapping("sample index")
                }
                zones.append(Zone(
                    name: name, sampleIndex: Int(rawSample),
                    groupIndex: rawGroup == UInt32.max ? nil : Int(rawGroup),
                    rootNote: root, keyLow: low, keyHigh: high,
                    velocityLow: velLow, velocityHigh: velHigh,
                    flags: data[body], fineTuning: signed(data[body + 2]),
                    coarseTuning: length > 80 ? signed(data[body + 80]) : 0,
                    pan: signed(data[body + 3]), gain: signed(data[body + 4]),
                    trimStart: dword(data, body + 12),
                    trimEnd: dword(data, body + 16),
                    loopStart: dword(data, body + 20),
                    loopEnd: dword(data, body + 24),
                    loopCrossfadeMilliseconds: dword(data, body + 28),
                    loopFlags: data[body + 33], loopDirection: data[body + 34]))
                if zones.count > 4_096 { throw EXSError.tooManyBlocks }
            case 2:
                guard length >= 92, groups[index] == nil else {
                    throw EXSError.invalidMapping("group record")
                }
                groups[index] = Group(
                    index: index, name: name,
                    mute: data[body + 3] & 16 != 0,
                    velocityLow: data[body + 5],
                    velocityHigh: data[body + 6],
                    releaseTrigger: data[body + 73] != 0,
                    roundRobinPosition: Int32(bitPattern: dword(data, body + 80)),
                    enableByType: data[body + 84],
                    velocityCrossfade: signed(data[body + 32]),
                    keyCrossfade: signed(data[body + 35]))
                if groups.count > 1_024 { throw EXSError.tooManyBlocks }
            case 3:
                // Old EXS files may only store a path; later versions have
                // a separate filename at body byte 336.
                guard length >= 336, samples[index] == nil else {
                    throw EXSError.invalidMapping("sample record")
                }
                let path = cString(data, at: body + 80, size: 256)
                let filename = length >= 592
                    ? cString(data, at: body + 336, size: 256)
                    : ""
                let rate = dword(data, body + 8)
                let lengthFrames = dword(data, body + 4)
                guard rate > 0 else {
                    throw EXSError.invalidMapping("sample rate")
                }
                samples[index] = Sample(index: index, name: name,
                    directoryOrPath: path, fileName: filename,
                    sampleRate: rate, sampleLength: lengthFrames)
                if samples.count > 4_096 { throw EXSError.tooManyBlocks }
            case 4:
                warnings.insert("EXS24 instrument-level synthesis parameters and effects are not yet translated.")
            default:
                break
            }
            blockCount += 1
            if blockCount > 12_000 { throw EXSError.tooManyBlocks }
            offset += 84 + length
        }
        guard let instrumentName else { throw EXSError.missingInstrument }
        guard !zones.isEmpty else { throw EXSError.noZones }
        guard !samples.isEmpty else { throw EXSError.noSamples }

        // Validate record linkages before any audio file access.
        for zone in zones {
            guard samples[zone.sampleIndex] != nil else {
                throw EXSError.invalidMapping("zone references missing sample \(zone.sampleIndex)")
            }
            if let groupIndex = zone.groupIndex, groups[groupIndex] == nil {
                throw EXSError.invalidMapping("zone references missing group \(groupIndex)")
            }
        }
        return Catalog(name: instrumentName, zones: zones, groups: groups,
                       samples: samples, warnings: warnings.sorted())
    }
}
