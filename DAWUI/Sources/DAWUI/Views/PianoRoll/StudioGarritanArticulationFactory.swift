import Foundation
import DAWCore

/// Factory keyswitch maps are derived only from the shipped GPO5 manual
/// catalog, for an exact Standard-set ARIA program. Manual note names follow
/// Garritan's documented C4 = MIDI 60 convention.
enum StudioGarritanArticulationFactory {
    enum Resolution {
        case ready(StudioArticulationMap)
        case needsReview(String)
        case instantOrchestra
        case notKeyswitchInstrument
    }

    private struct Catalog: Decodable {
        struct Assignment: Decodable {
            let note: String
            let articulation: String
        }
        struct Patch: Decodable {
            let patch: String
            let keyswitches: [Assignment]
        }
        let patches: [Patch]
    }

    /// Names reused for DIFFERENT patches in the official GPO5 directory,
    /// or containing percussion playback-note ranges mixed with KS triggers.
    /// These are shown in the reference browser, not armed automatically.
    private static let manualReviewPatches: Set<String> = [
        "Violas KS", "Cellos KS", "Basses KS",
        "Percussion Accessories KS", "Snares KS",
        "Timpani 1 KS", "Timpani 2 KS", "Timpani 3 KS"
    ]

    private static func bundledCatalog() -> Data? {
        guard let url = Bundle.module.url(forResource: "GPO5_keyswitch_catalog",
                                          withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Caller may supply an in-memory fixture; normal usage loads the
    /// resource already bundled by Package.swift in the DAWUI module.
    static func resolve(programID: String?, catalogData: Data? = nil) -> Resolution {
        guard let programID,
              let separator = programID.firstIndex(of: ":") else {
            return .notKeyswitchInstrument
        }
        let library = String(programID[..<separator])
        let path = String(programID[programID.index(after: separator)...])
        if library == "Garritan Instant Orchestra" { return .instantOrchestra }
        guard library == "Garritan Personal Orchestra 5" else {
            return .notKeyswitchInstrument
        }
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else {
            return .needsReview("Garritan patch identity is unavailable")
        }
        let patchName = last.replacingOccurrences(
            of: ".sfz", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard patchName.uppercased().contains("KS") else {
            return .notKeyswitchInstrument
        }
        // Notation uses different octave offsets. GPO5's published directory
        // describes Standard ONLY; never extrapolate an offset from GPO4.
        if components.contains(where: { $0.caseInsensitiveCompare("Notation") == .orderedSame })
            || patchName.lowercased().hasPrefix("n-") {
            return .needsReview("Notation-set keyswitch octaves are not given by the Standard GPO5 table")
        }
        guard components.first?.caseInsensitiveCompare("Standard") == .orderedSame else {
            return .needsReview("The selected GPO5 program is not confirmed to be from the Standard set")
        }
        if manualReviewPatches.contains(patchName) {
            return .needsReview("This GPO5 patch name is ambiguous or mixes playback-note ranges and keyswitches in the manual")
        }
        guard let data = catalogData ?? bundledCatalog(),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return .needsReview("The bundled GPO5 manual keyswitch catalog is missing or invalid")
        }
        let matches = catalog.patches.filter {
            $0.patch.caseInsensitiveCompare(patchName) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            return .needsReview("No unique keyswitch entry exists for this exact GPO5 program")
        }
        guard !match.keyswitches.isEmpty else {
            return .needsReview("No documented keyswitches for this program")
        }

        var usedIDs = Set<String>()
        var usedNumbers = Set<Int>()
        var definitions: [StudioArticulationDefinition] = []
        for switchValue in match.keyswitches {
            guard let pitch = NoteData.pitch(from: switchValue.note),
                  !switchValue.articulation.isEmpty,
                  switchValue.articulation.count <= 70,
                  !switchValue.articulation.contains("–"),
                  usedNumbers.insert(Int(pitch)).inserted else {
                return .needsReview("The published mapping contains overlapping, range, or unparseable notes")
            }
            let canonical = stableArticulationID(switchValue.articulation)
            var key = canonical
            if !usedIDs.insert(key).inserted {
                key += "-\\(Int(pitch))"
                guard usedIDs.insert(key).inserted else {
                    return .needsReview("The published articulations are not uniquely named")
                }
            }
            let name = switchValue.articulation
            definitions.append(StudioArticulationDefinition(
                id: key,
                name: name,
                group: "GPO5",
                colorHex: color(for: canonical),
                actions: [StudioArticulationAction(
                    kind: .keyswitch, number: Int(pitch),
                    value: 100, channel: 0, holdForNote: false)]
            ))
        }
        return .ready(StudioArticulationMap(
            name: "GPO5 • \\(patchName)",
            articulations: definitions,
            factoryProgramID: programID,
            isFactoryDefault: true))
    }

    private static func stableArticulationID(_ label: String) -> String {
        let normalized = label.lowercased()
        if normalized == "sustains" || normalized == "sustain" ||
           normalized == "sustainvib" { return "sustain" }
        if normalized == "pizz" || normalized == "pizzicato" {
            return "pizzicato"
        }
        if normalized == "staccato" { return "staccato" }
        if normalized == "spiccato" { return "spiccato" }
        if normalized == "legato" { return "legato" }
        if normalized == "tremolo" { return "tremolo" }
        let key = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
        return key.isEmpty ? "articulation" : key
    }

    private static func color(for key: String) -> String {
        switch key {
        case "sustain": return "#5286C6"
        case "pizzicato": return "#A27DD2"
        case "staccato": return "#D49A51"
        case "spiccato": return "#DC794A"
        case "legato": return "#4CA87D"
        case "tremolo": return "#CA769E"
        default: return "#6D93AB"
        }
    }

    static let instantOrchestraPerformanceNotes = [
        "No keyswitch articulations are present in Instant Orchestra.",
        "CC1, CC2 and CC11 control dynamics in sustaining sounds.",
        "CC104 toggles GM (velocity dynamics) and GPO (mod-wheel dynamics) modes.",
        "Blending Textures use CC1 and/or CC11 for crossfading.",
        "On Blending Textures patches, CC30, CC31 and CC32 adjust the texture layers."
    ]
}
