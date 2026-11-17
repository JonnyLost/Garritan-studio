import Foundation

/// Bounded, read-only ZIP inventory. Parsing the central directory ourselves
/// avoids invoking an extractor on untrusted archive paths.
public enum StudioSamplerZIPArchive {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let uncompressedBytes: UInt64
        public let compressedBytes: UInt64
        public let isDirectory: Bool
    }
    public struct Inventory: Sendable {
        public let entries: [Entry]
        public let candidates: [StudioSamplerImportDiscovery.Candidate]
        public let totalUncompressedBytes: UInt64
    }
    public enum ArchiveError: Error, Equatable {
        case unreadable, invalidArchive, unsupportedArchive, unsafePath
        case tooManyEntries, oversizedArchive, duplicatePath
    }

    private static func u16(_ bytes: Data, _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
    private static func u32(_ bytes: Data, _ offset: Int) -> UInt64 {
        UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8) |
        (UInt64(bytes[offset + 2]) << 16) | (UInt64(bytes[offset + 3]) << 24)
    }

    /// Reject encrypted, ZIP64, multi-disk, and unsupported compression archives.
    /// No files are extracted, and the archive remains unchanged.
    public static func inspect(_ url: URL,
                               maxEntries: Int = 20_000,
                               maxTotalBytes: UInt64 = 4_000_000_000,
                               maxSingleFileBytes: UInt64 = 1_000_000_000) throws -> Inventory {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchiveError.unreadable
        }
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw ArchiveError.invalidArchive }
        let tailSize = Int(min(length, 65_557))
        try handle.seek(toOffset: length - UInt64(tailSize))
        let tail = try handle.read(upToCount: tailSize) ?? Data()
        guard tail.count == tailSize else { throw ArchiveError.invalidArchive }
        var end: Int?
        if tailSize >= 22 {
            for i in stride(from: tailSize - 22, through: 0, by: -1) {
                if u32(tail, i) == 0x06054b50 &&
                    i + 22 + u16(tail, i + 20) == tailSize {
                    end = i
                    break
                }
            }
        }
        guard let e = end else { throw ArchiveError.invalidArchive }
        guard u16(tail, e + 4) == 0, u16(tail, e + 6) == 0,
              u16(tail, e + 8) == u16(tail, e + 10) else {
            throw ArchiveError.unsupportedArchive
        }
        let count = u16(tail, e + 10)
        guard count <= max(1, min(maxEntries, 100_000)) else {
            throw ArchiveError.tooManyEntries
        }
        let centralLength = u32(tail, e + 12)
        let centralOffset = u32(tail, e + 16)
        guard count != 0xFFFF, centralLength != 0xFFFFFFFF,
              centralOffset != 0xFFFFFFFF,
              centralOffset <= length, centralLength <= length - centralOffset,
              centralLength <= 20_000_000 else {
            throw ArchiveError.unsupportedArchive
        }
        try handle.seek(toOffset: centralOffset)
        let directory = try handle.read(upToCount: Int(centralLength)) ?? Data()
        guard directory.count == Int(centralLength) else {
            throw ArchiveError.invalidArchive
        }
        var offset = 0
        var total: UInt64 = 0
        var entries: [Entry] = []
        var candidates: [StudioSamplerImportDiscovery.Candidate] = []
        var seen = Set<String>()
        for _ in 0..<count {
            guard offset + 46 <= directory.count,
                  u32(directory, offset) == 0x02014b50 else {
                throw ArchiveError.invalidArchive
            }
            let flags = u16(directory, offset + 8)
            let method = u16(directory, offset + 10)
            let compressed = u32(directory, offset + 20)
            let uncompressed = u32(directory, offset + 24)
            let nameLength = u16(directory, offset + 28)
            let extraLength = u16(directory, offset + 30)
            let commentLength = u16(directory, offset + 32)
            let endOffset = offset + 46 + nameLength + extraLength + commentLength
            guard endOffset <= directory.count else { throw ArchiveError.invalidArchive }
            guard flags & 1 == 0, method == 0 || method == 8,
                  compressed != 0xFFFFFFFF, uncompressed != 0xFFFFFFFF,
                  u16(directory, offset + 34) == 0 else {
                throw ArchiveError.unsupportedArchive
            }
            let nameData = directory.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8),
                  !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
                  !name.contains(":"), !name.contains("\0"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !name.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0 == ".." || $0 == "." || $0.isEmpty &&
                        $0 != name.split(separator: "/").last }) else {
                throw ArchiveError.unsafePath
            }
            let isDirectory = name.hasSuffix("/")
            let components = name.split(separator: "/")
            guard !components.isEmpty, components.count <= 32 else {
                throw ArchiveError.unsafePath
            }
            let normalized = components.joined(separator: "/").lowercased()
            guard seen.insert(normalized).inserted else {
                throw ArchiveError.duplicatePath
            }
            // Unix mode bits in the central directory can identify symlinks.
            let madeBy = u16(directory, offset + 4) >> 8
            let unixMode = UInt16((u32(directory, offset + 38) >> 16) & 0xFFFF)
            if madeBy == 3 && (unixMode & 0xF000) == 0xA000 {
                throw ArchiveError.unsafePath
            }
            guard uncompressed <= maxSingleFileBytes,
                  total <= maxTotalBytes,
                  uncompressed <= maxTotalBytes - total else {
                throw ArchiveError.oversizedArchive
            }
            total += uncompressed
            entries.append(Entry(path: name, uncompressedBytes: uncompressed,
                                 compressedBytes: compressed, isDirectory: isDirectory))
            if !isDirectory {
                let (kind, readiness) = StudioSamplerImportDiscovery.classify(
                    URL(fileURLWithPath: name))
                if kind != .unknown {
                    candidates.append(.init(relativePath: name, kind: kind,
                                            readiness: readiness))
                }
            }
            offset = endOffset
        }
        guard offset == directory.count else { throw ArchiveError.invalidArchive }
        return Inventory(entries: entries, candidates: candidates,
                         totalUncompressedBytes: total)
    }
}
