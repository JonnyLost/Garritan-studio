import Foundation
import Compression

/// Native, offline reader for one verified legacy Kontakt K2_Container map.
/// NKI is a proprietary, evolving format: this is NOT a general Kontakt
/// decoder, DRM remover, monolith extractor, or script interpreter.
///
/// Only an unprotected zlib-wrapped, K2_Container XML mapping is accepted.
/// The XML data and compressed header are bounded; no sample audio is loaded
/// while reading the mapping. Modern or unsupported formats fail clearly.
public enum StudioSamplerNKIReader {
    public struct Zone: Sendable {
        public let samplePath: String
        public let rootKey: UInt8
        public let lowKey: UInt8
        public let highKey: UInt8
        public let lowVelocity: UInt8
        public let highVelocity: UInt8
        public let sampleStart: UInt32
        public let sampleEnd: UInt32?
        public let loopStart: UInt32?
        public let loopEnd: UInt32?
        public let releaseTrigger: Bool
        public let groupName: String
        public let warnings: [String]
    }

    public struct Catalog: Sendable {
        public let name: String
        public let zones: [Zone]
        public let warnings: [String]
        public let compressedBytes: Int
        public let documentBytes: Int
    }

    public enum NKIError: Error, LocalizedError {
        case unsupportedContainer
        case protectedOrUnknownFormat
        case damagedCompressedMap
        case oversizedInstrument
        case malformedXML
        case unsupportedMapping(String)
        case invalidZone(String)
        case noZones

        public var errorDescription: String? {
            switch self {
            case .unsupportedContainer:
                return "This NKI is not a supported legacy K2 instrument map."
            case .protectedOrUnknownFormat:
                return "This Kontakt instrument is protected, contains embedded samples, or uses an NKI generation Studio cannot read natively yet."
            case .damagedCompressedMap:
                return "The Kontakt instrument's compressed map is damaged or incomplete."
            case .oversizedInstrument:
                return "The Kontakt instrument exceeds Studio's safe metadata inspection limits."
            case .malformedXML:
                return "The Kontakt instrument map contains invalid XML."
            case .unsupportedMapping(let feature):
                return "This Kontakt instrument uses unsupported \(feature)."
            case .invalidZone(let reason):
                return "Invalid Kontakt sample zone: \(reason)."
            case .noZones:
                return "This Kontakt instrument has no supported playable sample zones."
            }
        }
    }

    private static let maxInstrumentBytes = 64 * 1024 * 1024
    private static let maxExpandedBytes = 16 * 1024 * 1024
    private static let headerScanLength = 256

    /// RFC1950 header validation; do not infer zlib solely from 0x78 0x9c.
    private static func isZlibHeader(_ data: Data, at index: Int) -> Bool {
        guard index + 2 <= data.count else { return false }
        let cmf = data[index], flg = data[index + 1]
        return cmf & 0x0f == 8 && cmf >> 4 <= 7 &&
            (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 &&
            flg & 0x20 == 0
    }

    private static func adler32(_ buffer: Data) -> UInt32 {
        let mod: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        // 5,552-byte blocks prevent overflow even on very large XML docs.
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + 5_552, buffer.count)
            for byte in buffer[offset..<end] {
                a += UInt32(byte)
                b += a
            }
            a %= mod
            b %= mod
            offset = end
        }
        return (b << 16) | a
    }

    /// Apple's native Compression API uses raw DEFLATE for the ZLIB codec.
    /// We validate and strip RFC1950's wrapper, then verify its Adler32.
    private static func inflatedDocument(_ data: Data) throws -> Data {
        guard data.count <= maxInstrumentBytes else {
            throw NKIError.oversizedInstrument
        }
        guard data.count >= 12 else {
            throw NKIError.unsupportedContainer
        }
        let limit = min(headerScanLength, data.count - 6)
        var candidateCount = 0
        for start in 0..<limit where isZlibHeader(data, at: start) {
            candidateCount += 1
            // Reject binary blobs that merely contain many coincidental
            // zlib-like byte pairs; never repeatedly allocate huge buffers.
            guard candidateCount <= 8 else {
                throw NKIError.protectedOrUnknownFormat
            }
            let offset = start + 2
            guard data.count - offset >= 5 else { continue }
            let payload = data.subdata(in: offset..<(data.count - 4))
            var inflated = Data(count: maxExpandedBytes + 1)
            let written = inflated.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        source.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 && written <= maxExpandedBytes else { continue }
            inflated.count = written
            let checksum = data.suffix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard adler32(inflated) == checksum else { continue }
            let prefix = inflated.prefix(512)
            guard prefix.starts(with: Data("<?xml".utf8)) ||
                    prefix.starts(with: Data("<K2_Container".utf8)) ||
                    prefix.containsSubsequence(Data("<K2_Container".utf8)) else {
                continue
            }
            return inflated
        }
        // Every other NKI is a separate compatibility task, not a reason
        // to scan for arbitrary "sampleFile" text or bypass file protection.
        throw NKIError.protectedOrUnknownFormat
    }

    /// Discover one XML mapping. No file creation, sample search or synth I/O.
    public static func inspect(_ url: URL) throws -> Catalog {
        guard url.pathExtension.lowercased() == "nki" else {
            throw NKIError.unsupportedContainer
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size]
        guard let count = size as? NSNumber, count.intValue <= maxInstrumentBytes else {
            throw NKIError.oversizedInstrument
        }
        let input = try Data(contentsOf: url, options: .mappedIfSafe)
        let document = try inflatedDocument(input)
        // XMLParser's entity controls forbid external lookups; reject DTDs
        // outright so internal recursive entity expansion cannot exhaust RAM.
        let upper = Data(document.map { byte in
            (97...122).contains(byte) ? byte - 32 : byte
        })
        guard upper.range(of: Data("<!DOCTYPE".utf8)) == nil,
              upper.range(of: Data("<!ENTITY".utf8)) == nil else {
            throw NKIError.malformedXML
        }
        let parser = XMLParser(data: document)
        // No external-entity expansion, network access, or DTD resolution.
        parser.shouldResolveExternalEntities = false
        let collector = Collector()
        parser.delegate = collector
        guard parser.parse(), !collector.invalid else {
            throw NKIError.malformedXML
        }
        guard collector.hasContainer, collector.programCount == 1 else {
            throw NKIError.unsupportedMapping("multi-program or non-K2 containers")
        }
        guard !collector.hasScript, !collector.hasModulator else {
            throw NKIError.unsupportedMapping("Kontakt scripting or advanced modulation")
        }
        guard !collector.rawZones.isEmpty else { throw NKIError.noZones }
        guard collector.rawZones.count <= 128 else {
            throw NKIError.oversizedInstrument
        }

        var zones: [Zone] = []
        var warnings = Set<String>()
        let groupMap = collector.groupValues
        let groupNames = collector.groupNames
        let program = collector.programValues

        for raw in collector.rawZones {
            let map = raw.values
            let group = groupMap[raw.groupIndex] ?? [:]
            func number(_ source: [String: String], _ key: String,
                        fallback: Int, range: ClosedRange<Int>) throws -> Int {
                guard let string = source[key] else { return fallback }
                guard let value = Int(string), range.contains(value) else {
                    throw NKIError.invalidZone("\(key) is outside allowed range")
                }
                return value
            }
            func bool(_ source: [String: String], _ key: String,
                      fallback: Bool) throws -> Bool {
                guard let text = source[key]?.lowercased() else { return fallback }
                if ["yes", "true", "1"].contains(text) { return true }
                if ["no", "false", "0"].contains(text) { return false }
                throw NKIError.invalidZone("invalid \(key)")
            }
            let sample = map["sampleFile"] ?? ""
            guard !sample.isEmpty else {
                throw NKIError.invalidZone("missing sampleFile")
            }
            let keyLow = max(try number(map, "lowKey", fallback: 0, range: 0...127),
                             try number(program, "lowKey", fallback: 0, range: 0...127),
                             try number(group, "lowKey", fallback: 0, range: 0...127))
            let keyHigh = min(try number(map, "highKey", fallback: 127, range: 0...127),
                              try number(program, "highKey", fallback: 127, range: 0...127),
                              try number(group, "highKey", fallback: 127, range: 0...127))
            let velocityLow = max(1,
                try number(map, "lowVelo", fallback: 0, range: 0...127),
                try number(program, "lowVelocity", fallback: 0, range: 0...127),
                try number(group, "lowVelocity", fallback: 0, range: 0...127))
            let velocityHigh = min(
                try number(map, "highVelo", fallback: 127, range: 0...127),
                try number(program, "highVelocity", fallback: 127, range: 0...127),
                try number(group, "highVelocity", fallback: 127, range: 0...127))
            if keyLow > keyHigh || velocityLow > velocityHigh { continue }
            let root = try number(map, "rootKey", fallback: 60, range: 0...127)
            let trimStart = try number(map, "sampleStart",
                                       fallback: 0, range: 0...500_000_000)
            let trimEnd = try number(map, "sampleEnd",
                                     fallback: 0, range: 0...500_000_000)
            let loopMode = try number(map, "loopMode", fallback: 0, range: 0...2)
            let release = try bool(group, "releaseTrigger", fallback: false)
            guard try bool(group, "keyTracking", fallback: true),
                  !(try bool(group, "reverse", fallback: false)) else {
                throw NKIError.unsupportedMapping(
                    "reverse playback or disabled key tracking")
            }
            // A K2 group can carry expressions, envelopes and controllers
            // beyond its sample map; never silently treat active scripting
            // as a faithfully converted instrument.
            if loopMode == 2 {
                throw NKIError.unsupportedMapping("Kontakt loop-until-end behavior")
            }
            if release && loopMode != 0 {
                throw NKIError.unsupportedMapping("looped release-trigger zones")
            }
            var loopStart: UInt32?
            var loopEnd: UInt32?
            if loopMode == 1 {
                let start = try number(map, "loopStart",
                                       fallback: -1, range: 0...500_000_000)
                let end = try number(map, "loopEnd",
                                     fallback: -1, range: 0...500_000_000)
                guard start + 4 <= end else {
                    throw NKIError.invalidZone("sustain loop bounds")
                }
                loopStart = UInt32(start)
                loopEnd = UInt32(end)
            }
            var zoneWarnings: [String] = []
            for (param, expected) in [("zoneVolume", "1.000000"),
                                      ("zonePan", "0"),
                                      ("zoneTune", "1.000000")] {
                if let actual = map[param],
                   Double(actual) != Double(expected) {
                    zoneWarnings.append("Kontakt \(param) is not yet preserved.")
                }
            }
            if map.keys.contains(where: { $0.lowercased().contains("fade") }) {
                zoneWarnings.append("Kontakt zone crossfades are not yet reproduced.")
            }
            warnings.formUnion(zoneWarnings)
            zones.append(Zone(samplePath: sample,
                              rootKey: UInt8(root),
                              lowKey: UInt8(keyLow), highKey: UInt8(keyHigh),
                              lowVelocity: UInt8(velocityLow),
                              highVelocity: UInt8(velocityHigh),
                              sampleStart: UInt32(trimStart),
                              sampleEnd: trimEnd == 0 ? nil : UInt32(trimEnd),
                              loopStart: loopStart, loopEnd: loopEnd,
                              releaseTrigger: release,
                              groupName: groupNames[raw.groupIndex] ?? "Kontakt Group",
                              warnings: zoneWarnings))
        }
        guard !zones.isEmpty else { throw NKIError.noZones }
        warnings.insert("Kontakt filters, envelopes, effects and continuous modulation are not converted by this first NKI importer.")
        return Catalog(name: collector.programName.isEmpty
                           ? url.deletingPathExtension().lastPathComponent
                           : collector.programName,
                       zones: zones, warnings: warnings.sorted(),
                       compressedBytes: input.count,
                       documentBytes: document.count)
    }

    /// XMLParser is bounded to one K2 program and known descendants. No
    /// DTD, network or entity lookups. This is metadata, never MIDI script.
    private final class Collector: NSObject, XMLParserDelegate {
        struct RawZone { var groupIndex: Int; var values: [String: String] = [:] }
        var invalid = false
        var hasContainer = false
        var programCount = 0
        var programName = ""
        var programValues: [String: String] = [:]
        var groupNames: [Int: String] = [:]
        var groupValues: [Int: [String: String]] = [:]
        var rawZones: [RawZone] = []
        var hasScript = false
        var hasModulator = false
        private var path: [String] = []
        private var currentGroup: Int?
        private var currentZone: RawZone?
        private var groupSequence = 0

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            path.append(element)
            if path.count == 1 { hasContainer = element == "K2_Container" }
            if element == "K2_Program" {
                programCount += 1
                programName = attributes["name"] ?? ""
            }
            if element == "K2_Group" {
                currentGroup = groupSequence
                groupNames[groupSequence] = attributes["name"] ?? "Kontakt Group"
                groupValues[groupSequence] = [:]
                groupSequence += 1
            }
            if element == "Zone", let group = currentGroup {
                currentZone = RawZone(groupIndex: group)
            }
            if element == "V", let name = attributes["name"],
               let value = attributes["value"] {
                if currentZone != nil {
                    currentZone!.values[name] = value
                } else if path.suffix(2).elementsEqual(["Parameters", "V"]) {
                    if let group = currentGroup {
                        groupValues[group]?[name] = value
                    } else if programCount == 1 && path.contains("K2_Program") {
                        programValues[name] = value
                    }
                }
            }
            let lower = element.lowercased()
            if lower.contains("script") || lower == "ksp" {
                hasScript = true
            }
            if lower.contains("modulator") || lower.contains("insertfx") {
                hasModulator = true
            }
            if programCount > 1 || groupSequence > 512 ||
                rawZones.count > 128 || path.count > 40 {
                invalid = true
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if element == "Zone", let currentZone {
                rawZones.append(currentZone)
                self.currentZone = nil
            } else if element == "K2_Group" {
                currentGroup = nil
            }
            if !path.isEmpty { path.removeLast() }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
            invalid = true
        }
    }
}

private extension Data {
    func containsSubsequence(_ target: Data) -> Bool {
        guard !target.isEmpty, target.count <= count else { return false }
        return range(of: target) != nil
    }
}
