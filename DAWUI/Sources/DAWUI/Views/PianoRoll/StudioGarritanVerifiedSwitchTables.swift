import Foundation

/// Supplemental, manually verified tables from the official Garritan Personal
/// Orchestra 5 instrument directory. The legacy JSON catalog is a *single*
/// reference table per patch name; the GPO5 manual actually reuses the same
/// names across Section Strings, KS Groups, and even Choir.
///
/// An exact bank-folder context is mandatory for a colliding basename.
/// Without that context, the factory emits no automatic MIDI keyswitches.
enum StudioGarritanVerifiedSwitchTables {
    struct Entry {
        let note: String
        let label: String

        init(_ note: String, _ label: String) {
            self.note = note
            self.label = label
        }
    }

    enum Match {
        case notSpecial
        case verified([Entry])
        case needsReview(String)
    }

    private static let collidingStrings: Set<String> = [
        "Violins 1 KS", "Violins 2 KS", "Violas KS", "Cellos KS", "Basses KS"
    ]

    /// Source: GPO5 official directory, "KS Groups" section.
    /// Keyswitchs in this section do NOT have the same meanings as the
    /// identically named "Section Strings" instrument programs.
    private static let groupViolins: [Entry] = [
        .init("C2", "Sustains"), .init("C#2", "HeavyVib"),
        .init("D2", "Grand Detache"), .init("D#2", "Marcato"),
        .init("E2", "Martele"), .init("F2", "Pizzicato"),
        .init("F#2", "Portato"), .init("G2", "Col Legno"),
        .init("G#2", "Sautille"), .init("A2", "Spiccato"),
        .init("A#2", "Staccato"), .init("B2", "Sul Tasto")
    ]
    private static let groupViolas: [Entry] = [
        .init("C2", "Sustains"), .init("C#2", "HeavyVib"),
        .init("D2", "Grand Detache"), .init("D#2", "Martele Agg"),
        .init("E2", "Martele"), .init("F2", "Pizzicato"),
        .init("F#2", "Portato"), .init("G2", "Col Legno"),
        .init("G#2", "Spiccato")
    ]
    private static let groupCellos: [Entry] = [
        .init("C1", "Sustains"), .init("C#1", "HeavyVib"),
        .init("D1", "Grand Detache"), .init("D#1", "Marcato"),
        .init("E1", "Martele"), .init("F1", "Pizzicato"),
        .init("F#1", "Col Legno"), .init("G1", "Spiccato"),
        .init("G#1", "Staccato")
    ]
    private static let groupBasses: [Entry] = [
        .init("C0", "Sustains"), .init("C#0", "HeavyVib"),
        .init("D0", "Grand Detache"), .init("D#0", "Staccato"),
        .init("E0", "Staccato Agg"), .init("F0", "Pizzicato"),
        .init("F#0", "Col Legno"), .init("G0", "Snap Pizz")
    ]

    /// Source: official GPO5 percussion directory. These are the **actual
    /// switch notes**, not the pitched/drum-playing ranges also printed
    /// beneath each patch. This distinction avoids incorrectly converting
    /// cowbells, snare hits, and timpani pitches into articulation changes.
    private static let percussion: [String: [Entry]] = [
        "Percussion Accessories KS": [
            .init("C3", "Standard single hits"),
            .init("D3", "Playable release trigger rolls")
        ],
        "Snares KS": [
            .init("C3", "Standard single hits"),
            .init("D3", "Playable release trigger rolls")
        ],
        "Timpani 1 KS": [
            .init("C1", "Standard single hits"),
            .init("D1", "Playable release trigger rolls")
        ],
        "Timpani 2 KS": [
            .init("C1", "Standard single hits"),
            .init("D1", "Playable release trigger rolls")
        ],
        "Timpani 3 KS": [
            .init("C1", "Standard single hits"),
            .init("D1", "Playable release trigger rolls"),
            .init("E1", "Pre-recorded timpani rolls")
        ]
    ]

    private static func folder(_ component: String) -> String {
        component.replacingOccurrences(
            of: #"^\s*\d+[\s._-]*"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func lookup(patch: String, components: [String]) -> Match {
        let folders = Set(components.dropFirst().dropLast().map(folder))
        if let switches = percussion[patch] {
            // MIDI patches must originate from a percussion bank, not
            // merely share the filename of a known percussion program.
            guard folders.contains("percussion") ||
                  folders.contains("orchestral percussion") else {
                return .needsReview("Percussion folder identity is not confirmed")
            }
            return .verified(switches)
        }
        guard collidingStrings.contains(patch) else { return .notSpecial }

        if folders.contains("ks groups") {
            switch patch {
            case "Violins 1 KS", "Violins 2 KS":
                return .verified(groupViolins)
            case "Violas KS": return .verified(groupViolas)
            case "Cellos KS": return .verified(groupCellos)
            case "Basses KS": return .verified(groupBasses)
            default: return .needsReview("Unrecognized KS Groups patch")
            }
        }
        if folders.contains("section strings") {
            // The existing GPO5 manual JSON is drawn from this table.
            return .notSpecial
        }
        if folders.contains("choir") && patch == "Basses KS" {
            // Choir's Basses KS has only two vowel switches, not
            // pizzicato / bowing articulations.
            return .verified([
                .init("C1", "Aahs"), .init("D1", "Ohs")
            ])
        }
        return .needsReview(
            "GPO5 reuses this patch name in Section Strings, KS Groups or Choir. An exact bank folder is required.")
    }
}
