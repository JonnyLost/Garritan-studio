import Foundation

/// Offline, bounded GigaSampler/GigaStudio RIFF/DLS catalog reader.
///
/// GIG region 3lnk dimension links are NOT interchangeable with DLS wlnk.
/// This first compatibility stage imports only single-dimension, uncompressed
/// PCM regions, and explicitly rejects other dimensions or compressed waves.
/// No GPL-licensed libgig code is linked or copied into Studio.
public enum StudioSamplerGIGReader {
    public struct SampleParameters: Sendable {
        public let root: UInt8
        public let loopStart: UInt32?
        public let loopEnd: UInt32?
    }

    public struct Wave: Sendable {
        public let name: String
        public let format: UInt16
        public let channels: UInt16
        public let bitsPerSample: UInt16
        public let sampleRate: UInt32
        public let blockAlign: UInt16
        public let dataOffset: UInt64
        public let dataSize: UInt64
        public let poolOffset: UInt32
        public let parameters: SampleParameters?
    }

    public struct Region: Sendable {
        public let keyLow: UInt8
        public let keyHigh: UInt8
        public let velocityLow: UInt8
        public let velocityHigh: UInt8
        public let sampleTableIndex: UInt32?
        public let dimensionCount: UInt32
        public let parameters: SampleParameters?
        public let warnings: [String]
    }

    public struct Instrument: Sendable {
        public let name: String
        public let bank: UInt32
        public let program: UInt32
        public let regions: [Region]
    }

    public struct Catalog: Sendable {
        public let instruments: [Instrument]
        public let waves: [Wave]
        /// Maps region sample-table indices to the wave-pool array.
        public let sampleIndexToWave: [Int?]
        public let warnings: [String]
        public let fileSize: UInt64
    }

    public enum GIGError: Error, LocalizedError {
        case invalidContainer
        case invalidChunk(String)
        case unsupportedContainer
        case tooManyEntries
        case incompleteFile
        public var errorDescription: String? {
            switch self {
            case .invalidContainer:
                return "This is not a supported RIFF/DLS-based .gig file."
            case .invalidChunk(let item):
                return "The GigaStudio instrument contains an invalid \(item) chunk."
            case .unsupportedContainer:
                return "This GigaStudio container layout is not supported yet."
            case .tooManyEntries:
                return "This GigaStudio file contains too many RIFF entries."
            case .incompleteFile:
                return "The GigaStudio file is truncated or damaged."
            }
        }
    }

    private struct Chunk {
        let id: String
        let offset: UInt64
        let length: UInt64
        let header: UInt64
        var end: UInt64 { offset + length }
    }

    private struct Scanner {
        let handle: FileHandle
        let size: UInt64

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, count <= 1_048_576,
                  offset <= size, UInt64(count) <= size - offset else {
                throw GIGError.incompleteFile
            }
            try handle.seek(toOffset: offset)
            var output = Data()
            while output.count < count {
                guard let bytes = try handle.read(upToCount: count - output.count),
                      !bytes.isEmpty else { throw GIGError.incompleteFile }
                output.append(bytes)
            }
            return output
        }

        func children(_ start: UInt64, _ end: UInt64) throws -> [Chunk] {
            guard start <= end, end <= size else { throw GIGError.incompleteFile }
            var cursor = start
            var result: [Chunk] = []
            while cursor < end {
                guard end - cursor >= 8 else { throw GIGError.incompleteFile }
                let header = try read(cursor, 8)
                let length = UInt64(StudioSamplerGIGReader.u32(header, 4))
                let payload = cursor + 8
                guard length <= end - payload else { throw GIGError.incompleteFile }
                result.append(Chunk(id: StudioSamplerGIGReader.fourCC(header, 0),
                                    offset: payload, length: length, header: cursor))
                guard result.count <= 131_072 else { throw GIGError.tooManyEntries }
                let pad = length & 1
                guard length + pad <= end - payload else { throw GIGError.incompleteFile }
                cursor = payload + length + pad
            }
            return result
        }

        func listType(_ chunk: Chunk) throws -> String? {
            guard chunk.id == "LIST", chunk.length >= 4 else { return nil }
            return StudioSamplerGIGReader.fourCC(try read(chunk.offset, 4), 0)
        }

        func children(of list: Chunk) throws -> [Chunk] {
            guard list.id == "LIST", list.length >= 4 else {
                throw GIGError.invalidContainer
            }
            return try children(list.offset + 4, list.end)
        }

        func first(_ id: String, in chunks: [Chunk]) -> Chunk? {
            chunks.first { $0.id == id }
        }

        func firstList(_ type: String, in chunks: [Chunk]) throws -> Chunk? {
            for chunk in chunks where chunk.id == "LIST" {
                if try listType(chunk) == type { return chunk }
            }
            return nil
        }

        func lists(_ type: String, in chunks: [Chunk]) throws -> [Chunk] {
            var result: [Chunk] = []
            for chunk in chunks where chunk.id == "LIST" {
                if try listType(chunk) == type { result.append(chunk) }
            }
            return result
        }

        func displayName(_ list: Chunk?) throws -> String? {
            guard let list else { return nil }
            let records = try children(of: list)
            guard let entry = first("INAM", in: records) else { return nil }
            let bytes = try read(entry.offset, Int(min(256, entry.length)))
            return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func parameters(_ chunk: Chunk?, scanner: Scanner) throws -> SampleParameters? {
        guard let chunk else { return nil }
        guard chunk.length >= 20 else { throw GIGError.invalidChunk("wsmp") }
        let prefix = try scanner.read(chunk.offset, 20)
        let headerSize = UInt64(u32(prefix, 0))
        let root = u16(prefix, 4)
        let loopCount = u32(prefix, 16)
        guard headerSize >= 20, headerSize <= chunk.length, root <= 127,
              loopCount <= 1 else {
            throw GIGError.invalidChunk("wsmp")
        }
        guard loopCount == 1 else {
            return SampleParameters(root: UInt8(root),
                                    loopStart: nil, loopEnd: nil)
        }
        guard headerSize + 16 <= chunk.length else { throw GIGError.invalidChunk("wsmp loop") }
        let loop = try scanner.read(chunk.offset + headerSize, 16)
        let loopHeader = u32(loop, 0)
        let loopType = u32(loop, 4)
        let start = u32(loop, 8)
        let length = u32(loop, 12)
        guard loopHeader >= 16, loopType == 0, length >= 4,
              length <= UInt32.max - start else {
            throw GIGError.invalidChunk("wsmp loop")
        }
        return SampleParameters(root: UInt8(root),
                                loopStart: start, loopEnd: start + length)
    }

    /// Uses FileHandle's bounded reads to inspect huge sample pools without
    /// loading source audio into RAM. Only the RIFF32 layout is accepted here.
    public static func inspect(_ url: URL) throws -> Catalog {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let scanner = Scanner(handle: handle, size: fileSize)
        guard fileSize >= 12 else { throw GIGError.invalidContainer }
        let riff = try scanner.read(0, 12)
        guard fourCC(riff, 0) == "RIFF", fourCC(riff, 8) == "DLS " else {
            throw GIGError.invalidContainer
        }
        let declaredEnd = UInt64(u32(riff, 4)) + 8
        guard declaredEnd <= fileSize, declaredEnd >= 12 else {
            throw GIGError.incompleteFile
        }
        guard declaredEnd == fileSize else {
            // Some gig versions span multiple RIFF files / extended sizes;
            // do not silently omit any appended sample blocks.
            throw GIGError.unsupportedContainer
        }
        let root = try scanner.children(12, declaredEnd)
        guard let lins = try scanner.firstList("lins", in: root),
              let wvpl = try scanner.firstList("wvpl", in: root),
              let ptbl = scanner.first("ptbl", in: root) else {
            throw GIGError.invalidContainer
        }
        guard ptbl.length >= 8 else { throw GIGError.invalidChunk("ptbl") }
        let poolHeader = try scanner.read(ptbl.offset, 8)
        let poolHeaderSize = UInt64(u32(poolHeader, 0))
        let cueCount = UInt64(u32(poolHeader, 4))
        guard poolHeaderSize >= 8, poolHeaderSize <= ptbl.length,
              cueCount <= 131_072,
              cueCount * 4 <= ptbl.length - poolHeaderSize else {
            throw GIGError.invalidChunk("ptbl")
        }
        let cueBytes = try scanner.read(ptbl.offset + poolHeaderSize, Int(cueCount * 4))
        var cues: [UInt32] = []
        for index in 0..<Int(cueCount) {
            cues.append(u32(cueBytes, index * 4))
        }
        let poolChildren = try scanner.children(of: wvpl)
        let waveChunks = try scanner.lists("wave", in: poolChildren)
        guard !waveChunks.isEmpty else { throw GIGError.invalidContainer }
        var waves: [Wave] = []
        var offsets: [UInt32: Int] = [:]
        for (index, chunk) in waveChunks.enumerated() {
            let records = try scanner.children(of: chunk)
            guard let fmt = scanner.first("fmt ", in: records), fmt.length >= 16,
                  let audio = scanner.first("data", in: records) else {
                throw GIGError.invalidChunk("wave fmt/data")
            }
            let format = try scanner.read(fmt.offset, 16)
            let info = try scanner.displayName(scanner.firstList("INFO", in: records))
            let relative = chunk.header - (wvpl.offset + 4)
            guard relative <= UInt64(UInt32.max) else { throw GIGError.unsupportedContainer }
            let offset = UInt32(relative)
            guard offsets[offset] == nil else { throw GIGError.invalidChunk("wvpl") }
            offsets[offset] = index
            waves.append(Wave(name: info ?? "Sample \(index + 1)",
                              format: u16(format, 0), channels: u16(format, 2),
                              bitsPerSample: u16(format, 14),
                              sampleRate: u32(format, 4), blockAlign: u16(format, 12),
                              dataOffset: audio.offset, dataSize: audio.length,
                              poolOffset: offset,
                              parameters: try parameters(scanner.first("wsmp", in: records),
                                                         scanner: scanner)))
        }
        let mapping = cues.map { offsets[$0] }
        let instrumentsList = try scanner.children(of: lins)
        let instrumentChunks = try scanner.lists("ins ", in: instrumentsList)
        guard !instrumentChunks.isEmpty, instrumentChunks.count <= 8_192 else {
            throw GIGError.invalidContainer
        }
        var instruments: [Instrument] = []
        var warnings: Set<String> = []
        for (index, instrumentChunk) in instrumentChunks.enumerated() {
            let instrumentRecords = try scanner.children(of: instrumentChunk)
            guard let insh = scanner.first("insh", in: instrumentRecords),
                  insh.length >= 12,
                  let regionsList = try scanner.firstList("lrgn", in: instrumentRecords) else {
                throw GIGError.invalidChunk("instrument insh/lrgn")
            }
            let header = try scanner.read(insh.offset, 12)
            let bank = u32(header, 4)
            let program = u32(header, 8)
            let name = try scanner.displayName(
                scanner.firstList("INFO", in: instrumentRecords))
                ?? "Instrument \(index + 1)"
            let regionChunks = try scanner.children(of: regionsList)
            var regions: [Region] = []
            for regionChunk in regionChunks where regionChunk.id == "LIST" {
                let type = try scanner.listType(regionChunk)
                guard type == "rgn " || type == "rgn2" else { continue }
                let regionRecords = try scanner.children(of: regionChunk)
                guard let rgnh = scanner.first("rgnh", in: regionRecords),
                      rgnh.length >= 12 else { throw GIGError.invalidChunk("rgnh") }
                let r = try scanner.read(rgnh.offset, 12)
                let lowKey = u16(r, 0), highKey = u16(r, 2)
                let lowVelocity = u16(r, 4), highVelocity = u16(r, 6)
                guard lowKey <= highKey, highKey <= 127,
                      lowVelocity <= highVelocity, highVelocity <= 127 else {
                    throw GIGError.invalidChunk("region key/velocity range")
                }
                var tableIndex: UInt32?
                var dimensions: UInt32 = 1
                var regionWarnings: [String] = []
                if let gigLink = scanner.first("3lnk", in: regionRecords) {
                    guard gigLink.length >= 48 else { throw GIGError.invalidChunk("3lnk") }
                    let count = try scanner.read(gigLink.offset, 4)
                    dimensions = u32(count, 0)
                    guard dimensions > 0, dimensions <= 32,
                          dimensions & (dimensions - 1) == 0,
                          gigLink.length >= 44 + UInt64(dimensions) * 4 else {
                        throw GIGError.invalidChunk("3lnk dimension count")
                    }
                    if dimensions == 1 {
                        let cue = try scanner.read(gigLink.offset + 44, 4)
                        tableIndex = u32(cue, 0)
                    } else {
                        regionWarnings.append(
                            "This region has \(dimensions) GigaStudio dimension cases; conversion is not yet supported.")
                    }
                } else if let waveLink = scanner.first("wlnk", in: regionRecords) {
                    guard waveLink.length >= 12 else { throw GIGError.invalidChunk("wlnk") }
                    tableIndex = u32(try scanner.read(waveLink.offset + 8, 4), 0)
                    regionWarnings.append("DLS-style sample link without GIG dimension metadata.")
                } else {
                    regionWarnings.append("Region has no GigaStudio sample link.")
                }
                var sampleParameters = try parameters(
                    scanner.first("wsmp", in: regionRecords), scanner: scanner)
                if let programs = try scanner.firstList("3prg", in: regionRecords) {
                    let programRecords = try scanner.children(of: programs)
                    let dimensionChunks = try scanner.lists("3ewl", in: programRecords)
                    if dimensions == 1, let regionProgram = dimensionChunks.first {
                        let entries = try scanner.children(of: regionProgram)
                        sampleParameters = try parameters(
                            scanner.first("wsmp", in: entries),
                            scanner: scanner) ?? sampleParameters
                    } else if dimensions == 1 && dimensionChunks.isEmpty {
                        regionWarnings.append("Region has no 3ewl articulation parameters.")
                    }
                    if !dimensionChunks.isEmpty && UInt32(dimensionChunks.count) != dimensions {
                        regionWarnings.append("GigaStudio dimension/articulation counts differ.")
                    }
                }
                if let sampleIndex = tableIndex,
                   (Int(sampleIndex) >= mapping.count ||
                    mapping[Int(sampleIndex)] == nil) {
                    regionWarnings.append("Sample pool table reference is missing.")
                }
                if regionRecords.contains(where: { $0.id == "3lnk" }) {
                    warnings.insert("GigaStudio articulation, filter and LFO parameters are not fully translated.")
                }
                regions.append(Region(
                    keyLow: UInt8(lowKey), keyHigh: UInt8(highKey),
                    velocityLow: UInt8(lowVelocity), velocityHigh: UInt8(highVelocity),
                    sampleTableIndex: tableIndex, dimensionCount: dimensions,
                    parameters: sampleParameters, warnings: regionWarnings))
                guard regions.count <= 4_096 else { throw GIGError.tooManyEntries }
            }
            instruments.append(Instrument(name: name, bank: bank,
                                          program: program, regions: regions))
        }
        return Catalog(instruments: instruments, waves: waves,
                       sampleIndexToWave: mapping, warnings: warnings.sorted(),
                       fileSize: fileSize)
    }
}
