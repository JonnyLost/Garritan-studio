import Foundation
import CryptoKit

/// Portable, self-contained native Studio instrument bundle:
/// Name.studioinstrument/manifest.json + Samples/*.wav (or original format).
/// Every sample is verified before changing a track or installing recordings.
public enum StudioSamplerInstrumentPackage {
    public static let fileExtension = "studioinstrument"

    public struct Metadata: Codable, Equatable, Sendable {
        public var name: String
        public var category: String
        public var tags: [String]

        public init(name: String, category: String = "Other", tags: [String] = []) {
            self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            self.category = String(category.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            self.tags = Array(Set(tags.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            }.filter { !$0.isEmpty })).sorted().prefix(20).map { $0 }
        }

        public var isValid: Bool {
            !name.isEmpty && name.count <= 120 &&
            !category.isEmpty && category.count <= 64 &&
            tags.count <= 20 && tags.allSatisfy { !$0.isEmpty && $0.count <= 40 }
        }
    }

    public struct LibraryItem: Identifiable, Sendable {
        public let url: URL
        public let metadata: Metadata
        public let zoneCount: Int
        public var id: String { url.path }
    }

    private struct Sample: Codable {
        var relativePath: String
        var byteCount: UInt64
        var sha256: String
    }

    private struct Manifest: Codable {
        var formatVersion: Int
        var metadata: Metadata
        var patch: StudioSamplerPatch
        var samples: [Sample]
    }

    public enum PackageError: Error, LocalizedError {
        case invalidPatch
        case invalidPackage
        case unsupportedVersion
        case unsafeFile
        case corruptSample(String)
        case destinationExists
        case noSamples

        public var errorDescription: String? {
            switch self {
            case .invalidPatch: return "The instrument mapping is not valid."
            case .invalidPackage: return "This is not a valid Studio instrument package."
            case .unsupportedVersion: return "This instrument was created with an unsupported format version."
            case .unsafeFile: return "An instrument package contains an unsafe file path or symbolic link."
            case .corruptSample(let name): return "The recording \(name) failed its integrity check."
            case .destinationExists: return "An instrument with this filename already exists."
            case .noSamples: return "Add and apply samples before exporting an instrument."
            }
        }
    }

    public static func libraryDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("GarritanStudio/SamplerInstruments",
                                             isDirectory: true)
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func checksum(_ url: URL) throws -> (bytes: UInt64, sha: String) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var bytes: UInt64 = 0
        while true {
            guard let data = try file.read(upToCount: 256 * 1024), !data.isEmpty else { break }
            bytes += UInt64(data.count)
            hash.update(data: data)
        }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func manifestURL(_ package: URL) -> URL {
        package.appendingPathComponent("manifest.json", isDirectory: false)
    }

    /// Validate the complete manifest and all source recordings. Never trust
    /// manifest-relative paths to determine a filesystem location.
    private static func read(_ package: URL, verifyAudio: Bool) throws -> Manifest {
        let fm = FileManager.default
        guard package.pathExtension.lowercased() == fileExtension,
              (try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
              regularFile(manifestURL(package)),
              let data = try? Data(contentsOf: manifestURL(package)),
              data.count <= 2_000_000,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw PackageError.invalidPackage }
        guard manifest.formatVersion == 1 else { throw PackageError.unsupportedVersion }
        guard manifest.metadata.isValid, manifest.patch.isValid,
              manifest.samples.count > 0, manifest.samples.count <= 128,
              Set(manifest.samples.map(\.relativePath)).count == manifest.samples.count
        else { throw PackageError.invalidPackage }
        let references = manifest.patch.zones.map(\.filePath)
        guard Set(references) == Set(manifest.samples.map(\.relativePath)),
              manifest.patch.zones.allSatisfy { $0.managedFileName == nil }
        else { throw PackageError.invalidPackage }

        let samplesDir = package.appendingPathComponent("Samples", isDirectory: true)
        guard (try? samplesDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
        else { throw PackageError.unsafeFile }
        let realRoot = samplesDir.resolvingSymlinksInPath().standardizedFileURL
        for entry in manifest.samples {
            let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "Samples",
                  StudioSamplerSampleLibrary.validManagedFileName(String(parts[1])),
                  entry.byteCount > 0,
                  entry.sha256.count == 64,
                  entry.sha256.allSatisfy { $0.isHexDigit }
            else { throw PackageError.unsafeFile }
            let candidate = samplesDir.appendingPathComponent(String(parts[1]))
            guard regularFile(candidate),
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                    .standardizedFileURL == realRoot
            else { throw PackageError.unsafeFile }
            if verifyAudio {
                let digest = try checksum(candidate)
                guard digest.bytes == entry.byteCount &&
                      digest.sha == entry.sha256.lowercased()
                else { throw PackageError.corruptSample(candidate.lastPathComponent) }
            }
        }
        _ = fm // Reserved for future on-disk format migrations.
        return manifest
    }

    public static func export(_ patch: StudioSamplerPatch,
                              metadata: Metadata,
                              to destination: URL) throws {
        guard patch.isValid, metadata.isValid else { throw PackageError.invalidPatch }
        guard !patch.zones.isEmpty else { throw PackageError.noSamples }
        guard destination.pathExtension.lowercased() == fileExtension
        else { throw PackageError.invalidPackage }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw PackageError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".studioinstrument-\(UUID().uuidString)",
                                                     isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("Samples", isDirectory: true),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var archived = patch
        var unique: [String: Sample] = [:]
        var samples: [Sample] = []

        for index in archived.zones.indices {
            let source = patch.zones[index].sampleURL
            guard regularFile(source) else { throw PackageError.unsafeFile }
            let key = source.resolvingSymlinksInPath().standardizedFileURL.path
            if unique[key] == nil {
                let filename = String(format: "%03d-", samples.count) + source.lastPathComponent
                let samplePath = "Samples/" + filename
                let copy = staging.appendingPathComponent(samplePath)
                try fm.copyItem(at: source, to: copy)
                let integrity = try checksum(copy)
                guard integrity.bytes > 0 else {
                    throw PackageError.corruptSample(source.lastPathComponent)
                }
                let entry = Sample(relativePath: samplePath,
                                   byteCount: integrity.bytes, sha256: integrity.sha)
                samples.append(entry)
                unique[key] = entry
            }
            archived.zones[index].filePath = unique[key]!.relativePath
            archived.zones[index].managedFileName = nil
        }

        let manifest = Manifest(formatVersion: 1, metadata: metadata,
                                patch: archived, samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(staging), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
    }

    /// Copies verified recordings into the app-owned sampler sample library.
    /// If any copy fails, the batch importer rolls back its new recordings.
    public static func load(_ package: URL,
                            into sampleDirectory: URL? = nil) throws -> (StudioSamplerPatch, Metadata) {
        let access = package.startAccessingSecurityScopedResource()
        defer { if access { package.stopAccessingSecurityScopedResource() } }
        let manifest = try read(package, verifyAudio: true)
        let inputs = manifest.samples.map {
            package.appendingPathComponent($0.relativePath)
        }
        let copied = try StudioSamplerSampleLibrary.importFiles(inputs, into: sampleDirectory)
        var patch = manifest.patch
        let byPath = Dictionary(uniqueKeysWithValues:
            zip(manifest.samples.map(\.relativePath), copied))
        for index in patch.zones.indices {
            guard let copiedURL = byPath[patch.zones[index].filePath] else {
                throw PackageError.invalidPackage
            }
            patch.zones[index].filePath = copiedURL.path
            patch.zones[index].managedFileName =
                StudioSamplerSampleLibrary.managedName(for: copiedURL, in: sampleDirectory)
        }
        return (patch, manifest.metadata)
    }

    public static func saveToLibrary(_ patch: StudioSamplerPatch,
                                     metadata: Metadata,
                                     in directory: URL? = nil) throws -> URL {
        let folder = try directory ?? libraryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = metadata.name.replacingOccurrences(
            of: #"[^A-Za-z0-9_-]+"#, with: "-", options: .regularExpression
        ).prefix(48)
        let destination = folder.appendingPathComponent(
            "\(name)-\(UUID().uuidString).\(fileExtension)", isDirectory: true
        )
        try export(patch, metadata: metadata, to: destination)
        return destination
    }

    public static func listLibrary(in directory: URL? = nil) throws -> [LibraryItem] {
        let folder = try directory ?? libraryDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .compactMap { url -> LibraryItem? in
                guard let manifest = try? read(url, verifyAudio: false) else { return nil }
                return LibraryItem(url: url, metadata: manifest.metadata,
                                   zoneCount: manifest.patch.zones.count)
            }
            .sorted { $0.metadata.name.localizedStandardCompare($1.metadata.name) == .orderedAscending }
    }

    public static func removeFromLibrary(_ url: URL, in directory: URL? = nil) throws {
        let root = try (directory ?? libraryDirectory()).resolvingSymlinksInPath()
            .standardizedFileURL
        guard url.pathExtension.lowercased() == fileExtension,
              url.resolvingSymlinksInPath().deletingLastPathComponent()
                .standardizedFileURL == root,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))
                .isSymbolicLink != true
        else { throw PackageError.unsafeFile }
        try FileManager.default.removeItem(at: url)
    }
}
