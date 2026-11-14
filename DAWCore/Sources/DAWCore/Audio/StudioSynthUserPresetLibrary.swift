import Foundation

/// Versioned, self-contained user presets for Studio's six native synthesis
/// engines and four-layer hybrids. Does not depend on Audio Units or plug-ins.
public enum StudioSynthUserPresetLibrary {
    public struct Preset: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public var name: String
        public var patch: StudioSynthPatch
        public var createdAt: Date

        public init(id: UUID = UUID(), name: String,
                    patch: StudioSynthPatch, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.patch = patch
            self.createdAt = createdAt
        }
    }

    public enum PresetError: LocalizedError {
        case invalidName
        case invalidPatch
        case invalidFormat
        case duplicateName

        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Enter a preset name between 1 and 80 characters."
            case .invalidPatch: return "The Synth patch contains invalid settings."
            case .invalidFormat: return "This is not a supported Studio Synth preset."
            case .duplicateName: return "A preset with this name already exists."
            }
        }
    }

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var preset: Preset
    }

    public static func directory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Garritan Studio/Presets/Studio Synth",
                                    isDirectory: true)
    }

    /// Names are user-facing only. File identities use UUIDs to prevent
    /// traversal, collisions and accidental overwrites.
    public static func save(name: String, patch: StudioSynthPatch,
                            in folder: URL = directory()) throws -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            throw PresetError.invalidName
        }
        guard patch.validate() else { throw PresetError.invalidPatch }
        let existing = try list(in: folder)
        guard !existing.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw PresetError.duplicateName }

        let preset = Preset(name: trimmed, patch: patch)
        let envelope = Envelope(format: "garritan.studio.synth.preset",
                                version: 1, preset: preset)
        let data = try JSONEncoder().encode(envelope)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(
            preset.id.uuidString).appendingPathExtension("studiosynth"),
            options: .atomic)
        return preset
    }

    public static func load(from file: URL) throws -> Preset {
        let data = try Data(contentsOf: file)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "garritan.studio.synth.preset",
              envelope.version == 1 else { throw PresetError.invalidFormat }
        let preset = envelope.preset
        guard !preset.name.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty,
              preset.name.count <= 80 else { throw PresetError.invalidName }
        guard preset.patch.validate() else { throw PresetError.invalidPatch }
        return preset
    }

    /// Ignore unrelated files and malformed presets rather than hiding all
    /// valid instruments when a single user file becomes corrupted.
    public static func list(in folder: URL = directory()) throws -> [Preset] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: folder,
                                               includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "studiosynth" }
            .compactMap { try? load(from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func fileURL(for preset: Preset,
                               in folder: URL = directory()) -> URL {
        folder.appendingPathComponent(preset.id.uuidString)
            .appendingPathExtension("studiosynth")
    }

    /// Changes the display name without changing the preset's stable file ID.
    /// A successful save is atomic, so interrupted writes do not corrupt it.
    public static func rename(_ preset: Preset, to newName: String,
                              in folder: URL = directory()) throws -> Preset {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw PresetError.invalidName
        }
        let url = fileURL(for: preset, in: folder)
        var updated = try load(from: url)
        guard updated.id == preset.id else { throw PresetError.invalidFormat }
        guard !(try list(in: folder)).contains(where: {
            $0.id != preset.id &&
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw PresetError.duplicateName }
        updated.name = name
        let data = try JSONEncoder().encode(Envelope(
            format: "garritan.studio.synth.preset",
            version: 1, preset: updated))
        try data.write(to: url, options: .atomic)
        return updated
    }

    /// Import a user-supplied .studiosynth patch. Assign a fresh UUID to
    /// avoid overwriting a different existing preset with the same file ID.
    /// Granular source WAVs are intentionally NOT bundled in this format.
    public static func importPreset(from file: URL,
                                    into folder: URL = directory()) throws -> Preset {
        guard file.pathExtension.lowercased() == "studiosynth" else {
            throw PresetError.invalidFormat
        }
        let imported = try load(from: file)
        return try save(name: imported.name, patch: imported.patch, in: folder)
    }

    public static func delete(_ preset: Preset,
                              in folder: URL = directory()) throws {
        let url = fileURL(for: preset, in: folder)
        try FileManager.default.removeItem(at: url)
    }
}
