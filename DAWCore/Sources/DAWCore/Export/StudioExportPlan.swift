import Foundation

/// User-facing render choices. A stem contains complete track signal chains;
/// there is never a separate fake "instrument" created for export.
public enum StudioExportMode: String, CaseIterable, Codable, Sendable {
    case stereoMix
    case monoMix
    case individualTracks
    case customStems

    public var title: String {
        switch self {
        case .stereoMix: return "Stereo Mix"
        case .monoMix: return "Mono Mix"
        case .individualTracks: return "Individual Tracks"
        case .customStems: return "Custom Stems"
        }
    }
}

public struct StudioExportStem: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var trackIDs: [TrackID]

    public init(id: UUID = UUID(), name: String, trackIDs: [TrackID]) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}

public struct StudioExportSettings: Sendable {
    public var mode: StudioExportMode
    /// Empty selects all tracks for individual-track export.
    public var selectedTrackIDs: [TrackID]
    public var stems: [StudioExportStem]
    /// A fixed safety tail for reverberation and note releases.
    public var tailSeconds: Double
    /// PCM WAV depth, 16 or 24 bits.
    public var bitDepth: Int

    public init(mode: StudioExportMode = .stereoMix,
                selectedTrackIDs: [TrackID] = [],
                stems: [StudioExportStem] = [],
                tailSeconds: Double = 3,
                bitDepth: Int = 24) {
        self.mode = mode
        self.selectedTrackIDs = selectedTrackIDs
        self.stems = stems
        self.tailSeconds = tailSeconds
        self.bitDepth = bitDepth
    }
}

public struct StudioExportPass: Sendable {
    public let name: String
    public let trackIDs: Set<TrackID>
    public let channelCount: Int
    public let fileName: String
}

/// Pure, deterministic planning. No audio graph mutation or file I/O.
/// Keeping this independent of AVFoundation enables regression tests for
/// selection, family grouping, filenames and render isolation.
public enum StudioExportPlan {
    public enum PlanningError: Error, LocalizedError {
        case emptyProject
        case invalidSettings
        case emptySelection
        case unknownTrack
        case duplicateStemName
        case invalidTempoMap
        case invalidDuration
        case unsupportedLoop

        public var errorDescription: String? {
            switch self {
            case .emptyProject: return "Add a track before exporting."
            case .invalidSettings: return "Choose 16-bit or 24-bit PCM and a tail between 0 and 15 seconds."
            case .emptySelection: return "Choose at least one track for every stem."
            case .unknownTrack: return "The export selection contains a track that no longer exists."
            case .duplicateStemName: return "Each exported stem needs a unique name."
            case .invalidTempoMap: return "Real-time export currently requires one constant tempo. Tempo maps with changes need the unified transport milestone."
            case .invalidDuration: return "The project has no valid exportable duration."
            case .unsupportedLoop: return "Looped clips cannot yet be exported with guaranteed identical playback."
            }
        }
    }

    /// Best-effort family discovery from existing Garritan catalog paths and
    /// native instrument identities. Unknown tracks remain individually
    /// selectable instead of silently disappearing from the stem builder.
    public static func family(for track: Track) -> String {
        if track.type == .audio { return "Audio" }
        if track.studioSamplerPatch != nil { return "Sampler" }
        if track.studioSynthEnabled == true ||
           track.studioFMEnabled == true ||
           track.studioAnalogEnabled == true { return "Synth" }
        let path = (track.garritanProgramID ?? track.name).lowercased()
        if path.contains("string") || path.contains("violin") ||
           path.contains("viola") || path.contains("cello") || path.contains("bass") {
            return "Strings"
        }
        if path.contains("brass") || path.contains("trumpet") ||
           path.contains("horn") || path.contains("trombone") || path.contains("tuba") {
            return "Brass"
        }
        if path.contains("woodwind") || path.contains("flute") ||
           path.contains("clarinet") || path.contains("oboe") ||
           path.contains("bassoon") || path.contains("sax") { return "Woodwinds" }
        if path.contains("percussion") || path.contains("timpani") ||
           path.contains("drum") { return "Percussion" }
        if path.contains("choir") || path.contains("vocal") { return "Choir" }
        if path.contains("piano") || path.contains("keyboard") ||
           path.contains("harp") { return "Keys" }
        return "Other"
    }

    public static func groupsByFamily(_ project: Project) -> [StudioExportStem] {
        let grouped = Dictionary(grouping: project.tracks, by: family(for:))
        return grouped.keys.sorted().compactMap { key in
            guard let tracks = grouped[key], !tracks.isEmpty else { return nil }
            return StudioExportStem(name: key, trackIDs: tracks.map(\.id))
        }
    }

    public static func makePasses(
        project: Project,
        settings: StudioExportSettings
    ) throws -> [StudioExportPass] {
        guard !project.tracks.isEmpty else { throw PlanningError.emptyProject }
        guard settings.tailSeconds.isFinite, (0...15).contains(settings.tailSeconds),
              settings.bitDepth == 16 || settings.bitDepth == 24 else {
            throw PlanningError.invalidSettings
        }
        let trackIDs = Set(project.tracks.map(\.id))
        guard trackIDs.count == project.tracks.count else { throw PlanningError.invalidSettings }

        var names = Set<String>()
        func makePass(name: String, ids: [TrackID], channels: Int) throws -> StudioExportPass {
            let selected = Set(ids)
            guard !selected.isEmpty else { throw PlanningError.emptySelection }
            guard selected.isSubset(of: trackIDs) else { throw PlanningError.unknownTrack }
            let safe = safeFilename(name)
            let normalized = safe.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                          locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalized).inserted else {
                throw PlanningError.duplicateStemName
            }
            return StudioExportPass(name: name, trackIDs: selected,
                                    channelCount: channels,
                                    fileName: safe + ".wav")
        }

        switch settings.mode {
        case .stereoMix, .monoMix:
            return [try makePass(name: project.name + (settings.mode == .monoMix ? " Mono" : " Mix"),
                                 ids: project.tracks.map(\.id),
                                 channels: settings.mode == .monoMix ? 1 : 2)]
        case .individualTracks:
            let ids = settings.selectedTrackIDs.isEmpty ?
                trackIDs : Set(settings.selectedTrackIDs)
            guard ids.isSubset(of: trackIDs) else { throw PlanningError.unknownTrack }
            return try project.tracks.filter { ids.contains($0.id) }.map {
                try makePass(name: $0.name, ids: [$0.id], channels: 2)
            }
        case .customStems:
            guard !settings.stems.isEmpty else { throw PlanningError.emptySelection }
            return try settings.stems.map {
                try makePass(name: $0.name, ids: $0.trackIDs, channels: 2)
            }
        }
    }

    public static func renderSeconds(project: Project, tailSeconds: Double) throws -> Double {
        guard project.sampleRate.isFinite, project.sampleRate > 0,
              project.tempo.bpm.isFinite, project.tempo.bpm > 0,
              project.tempoChanges.isEmpty else {
            throw PlanningError.invalidTempoMap
        }
        guard !project.tracks.flatMap(\.clips).contains(where: \.isLooped) else {
            throw PlanningError.unsupportedLoop
        }
        let duration = project.duration.seconds + tailSeconds
        guard duration.isFinite, duration > 0, duration < 60 * 60 * 12 else {
            throw PlanningError.invalidDuration
        }
        return duration
    }

    public static func isolatedProject(_ project: Project, for pass: StudioExportPass) -> Project {
        var snapshot = project
        snapshot.tracks = project.tracks
            .filter { pass.trackIDs.contains($0.id) }
            .map { track in
                var copy = track
                // Explicit stem membership overrides an unrelated mix solo.
                // Preserve track mute as an actual artistic choice.
                copy.isSolo = false
                return copy
            }
        snapshot.isLoopEnabled = false
        return snapshot
    }

    /// Reserved filenames, traversal and case-insensitive collisions are
    /// disallowed before writing anything to the user's export directory.
    public static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\n\r\t\0")
            .union(.controlCharacters)
        let fragments = value.components(separatedBy: invalid)
        let joined = fragments.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = joined.replacingOccurrences(of: "..", with: ".")
        let cleaned = String(collapsed.prefix(90)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
