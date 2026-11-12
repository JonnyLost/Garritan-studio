import Foundation

/// Entirely original, portable FM synthesis recipe. The patch is embedded in
/// the project track on load; deleting a user preset never breaks a project.
public struct StudioFMPreset: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case factory
        case user
    }

    public let id: String
    public let origin: Origin
    public var name: String
    public var summary: String
    public var category: StudioFMPresetCategory
    public var patch: StudioFMPatch

    public init(id: String, origin: Origin, name: String, summary: String,
                category: StudioFMPresetCategory, patch: StudioFMPatch) {
        self.id = id
        self.origin = origin
        self.name = name
        self.summary = summary
        self.category = category
        self.patch = patch
    }

    public func validate() throws {
        guard patch.validate(),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, summary.count <= 240 else {
            throw StudioFMPresetError.invalidPreset
        }
        switch origin {
        case .factory:
            guard id.hasPrefix("factory.fm.") else {
                throw StudioFMPresetError.invalidPreset
            }
        case .user:
            guard UUID(uuidString: id) != nil else {
                throw StudioFMPresetError.invalidPreset
            }
        }
    }
}

public enum StudioFMPresetCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case keys, bells, mallets, bass, lead, pad, percussion, texture

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum StudioFMPresetError: Error, LocalizedError {
    case invalidPreset
    case invalidName
    case factoryReadOnly
    case invalidIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidPreset:
            return "That Studio FM preset has invalid or unsupported synthesis data."
        case .invalidName:
            return "Choose a preset name between 1 and 80 characters."
        case .factoryReadOnly:
            return "Studio FM factory sounds cannot be modified or deleted."
        case .invalidIdentifier:
            return "The user preset identifier is invalid."
        }
    }
}

public enum StudioFMFactoryLibrary {
    private static func make(_ id: String, _ name: String,
                             _ category: StudioFMPresetCategory,
                             _ summary: String,
                             _ controls: [StudioFMParameter: Float]) -> StudioFMPreset {
        var patch = StudioFMPatch()
        for (parameter, value) in controls { patch.set(value, for: parameter) }
        return StudioFMPreset(id: "factory.fm." + id, origin: .factory,
                              name: name, summary: summary,
                              category: category, patch: patch)
    }

    /// Original four-operator FM patches. Each recipe contains only our
    /// engine's parameter values—no wave recordings or licensed banks.
    /// Operators are numbered 1 (main carrier) through 4.
    public static let presets: [StudioFMPreset] = [
        // Electric keys: paired/serial sine carriers, bright initial
        // modulator attack and a progressively softer decay.
        make("keys.aurora-electric", "Aurora Electric", .keys,
             "Warm, rounded electric keys with a bright initial tine.", [
                .algorithm: 0, .outputGain: 0.72,
                .op1Level: 0.84, .op1Decay: 1.7, .op1Sustain: 0.32, .op1Release: 0.5,
                .op2Ratio: 2, .op2Level: 0.48, .op2Decay: 0.24, .op2Sustain: 0.02,
                .op3Level: 0, .op4Level: 0
             ]),
        make("keys.velvet-tines", "Velvet Tines", .keys,
             "Mellow, soft-edged electric piano with a lingering tail.", [
                .algorithm: 1, .outputGain: 0.73,
                .op1Level: 0.78, .op1Decay: 2.4, .op1Sustain: 0.38, .op1Release: 0.95,
                .op2Ratio: 3, .op2Level: 0.32, .op2Decay: 0.17, .op2Sustain: 0.01,
                .op3Ratio: 1, .op3Level: 0.18, .op3Decay: 2.0, .op3Sustain: 0.25,
                .op4Level: 0
             ]),
        make("keys.crystal-stage", "Crystal Stage", .keys,
             "Clear, glassy electric keyboard with animated overtones.", [
                .algorithm: 2, .outputGain: 0.65,
                .op1Level: 0.78, .op1Decay: 1.8, .op1Sustain: 0.20, .op1Release: 0.68,
                .op2Ratio: 2.0, .op2Level: 0.45, .op2Decay: 0.28, .op2Sustain: 0.04,
                .op3Ratio: 6.0, .op3Level: 0.17, .op3Decay: 0.09, .op3Sustain: 0,
                .op4Ratio: 9, .op4Level: 0.07, .op4Decay: 0.08, .op4Sustain: 0
             ]),
        make("keys.midnight-organ", "Midnight Organ", .keys,
             "Stable organ-like harmonics built from four parallel carriers.", [
                .algorithm: 3, .outputGain: 0.94,
                .op1Ratio: 1, .op1Level: 1, .op1Sustain: 1,
                .op2Ratio: 2, .op2Level: 0.65, .op2Sustain: 1,
                .op3Ratio: 3, .op3Level: 0.38, .op3Sustain: 1,
                .op4Ratio: 4, .op4Level: 0.22, .op4Sustain: 1,
                .op1Release: 0.11, .op2Release: 0.11,
                .op3Release: 0.11, .op4Release: 0.11
             ]),

        // Bells: inharmonic operator ratios and slowly decaying carriers.
        make("bells.starlight", "Starlight Bell", .bells,
             "High, shimmering bell with a soft lower fundamental.", [
                .algorithm: 2, .outputGain: 0.68,
                .op1Level: 0.77, .op1Decay: 6.5, .op1Sustain: 0, .op1Release: 3.2,
                .op2Ratio: 2.79, .op2Level: 0.59, .op2Decay: 0.72, .op2Sustain: 0,
                .op3Ratio: 5.43, .op3Level: 0.31, .op3Decay: 0.38, .op3Sustain: 0,
                .op4Ratio: 8.2, .op4Level: 0.16, .op4Decay: 0.19, .op4Sustain: 0
             ]),
        make("bells.silver-arc", "Silver Arc", .bells,
             "Bright metallic chime with slightly inharmonic overtones.", [
                .algorithm: 0, .outputGain: 0.74,
                .op1Level: 0.86, .op1Decay: 4.2, .op1Sustain: 0, .op1Release: 2.5,
                .op2Ratio: 3.17, .op2Level: 0.67, .op2Decay: 0.63, .op2Sustain: 0,
                .op3Ratio: 7.6, .op3Level: 0.19, .op3Decay: 0.24, .op3Sustain: 0,
                .op4Level: 0
             ]),
        make("bells.temple-bronze", "Temple Bronze", .bells,
             "Low ceremonial bronze bell with a long decaying body.", [
                .algorithm: 1, .outputGain: 0.69, .feedback: 0.14,
                .op1Ratio: 0.5, .op1Level: 0.85, .op1Decay: 8.5, .op1Sustain: 0,
                .op1Release: 4.8,
                .op2Ratio: 1.47, .op2Level: 0.48, .op2Decay: 1.5, .op2Sustain: 0,
                .op3Ratio: 2.15, .op3Level: 0.42, .op3Decay: 6.0, .op3Sustain: 0,
                .op4Ratio: 5.1, .op4Level: 0.24, .op4Decay: 0.8, .op4Sustain: 0
             ]),
        make("bells.ice-pendant", "Ice Pendant", .bells,
             "Delicate high chime with an airy inharmonic afterglow.", [
                .algorithm: 2, .outputGain: 0.62,
                .op1Ratio: 2.0, .op1Level: 0.69, .op1Decay: 5.7, .op1Sustain: 0,
                .op1Release: 3.7,
                .op2Ratio: 4.32, .op2Level: 0.41, .op2Decay: 0.44, .op2Sustain: 0,
                .op3Ratio: 8.8, .op3Level: 0.22, .op3Decay: 0.22, .op3Sustain: 0,
                .op4Ratio: 12.6, .op4Level: 0.14, .op4Decay: 0.12, .op4Sustain: 0
             ]),

        // Mallets: fundamental plus brief upper partials.
        make("mallets.rosewood", "Rosewood Mallet", .mallets,
             "Warm wooden mallet attack with a short dark decay.", [
                .algorithm: 0, .outputGain: 0.75,
                .op1Level: 0.91, .op1Decay: 0.86, .op1Sustain: 0, .op1Release: 0.22,
                .op2Ratio: 3, .op2Level: 0.44, .op2Decay: 0.09, .op2Sustain: 0,
                .op3Level: 0, .op4Level: 0
             ]),
        make("mallets.glass-marimba", "Glass Marimba", .mallets,
             "Hollow resonant struck tone with a glassy upper attack.", [
                .algorithm: 1, .outputGain: 0.71,
                .op1Level: 0.86, .op1Decay: 1.25, .op1Sustain: 0, .op1Release: 0.35,
                .op2Ratio: 4, .op2Level: 0.39, .op2Decay: 0.08, .op2Sustain: 0,
                .op3Ratio: 2.0, .op3Level: 0.28, .op3Decay: 0.45, .op3Sustain: 0,
                .op4Ratio: 6.5, .op4Level: 0.23, .op4Decay: 0.07, .op4Sustain: 0
             ]),
        make("mallets.copper-keys", "Copper Keys", .mallets,
             "Hard metallic bar tone with concentrated early brilliance.", [
                .algorithm: 2, .outputGain: 0.65,
                .op1Level: 0.84, .op1Decay: 1.8, .op1Sustain: 0, .op1Release: 0.45,
                .op2Ratio: 3.93, .op2Level: 0.61, .op2Decay: 0.11, .op2Sustain: 0,
                .op3Ratio: 7.09, .op3Level: 0.26, .op3Decay: 0.08, .op3Sustain: 0,
                .op4Level: 0
             ]),
        make("mallets.satin-vibes", "Satin Vibes", .mallets,
             "Mellow vibraphone-like voice with a warm sustained decay.", [
                .algorithm: 1, .outputGain: 0.7,
                .op1Level: 0.77, .op1Decay: 5.1, .op1Sustain: 0.06,
                .op1Release: 2.2,
                .op2Ratio: 2.0, .op2Level: 0.24, .op2Decay: 0.26, .op2Sustain: 0,
                .op3Ratio: 1.0, .op3Level: 0.17, .op3Decay: 3.7, .op3Sustain: 0,
                .op4Level: 0
             ]),

        // Bass: clipped FM brightness with controlled low carriers.
        make("bass.furnace-sub", "Furnace Sub", .bass,
             "Centered low fundamental with a tight electric edge.", [
                .algorithm: 0, .outputGain: 0.8,
                .op1Ratio: 0.5, .op1Level: 0.95, .op1Sustain: 0.82,
                .op1Release: 0.11,
                .op2Ratio: 1, .op2Level: 0.31, .op2Decay: 0.15, .op2Sustain: 0.10,
                .op3Level: 0, .op4Level: 0
             ]),
        make("bass.fretless-current", "Fretless Current", .bass,
             "Rounded expressive bass with a brief plucked edge.", [
                .algorithm: 2, .outputGain: 0.78,
                .op1Ratio: 0.5, .op1Level: 0.88, .op1Decay: 0.7,
                .op1Sustain: 0.64, .op1Release: 0.26,
                .op2Ratio: 1, .op2Level: 0.24, .op2Decay: 0.13, .op2Sustain: 0,
                .op3Ratio: 4.0, .op3Level: 0.08, .op3Decay: 0.035,
                .op3Sustain: 0, .op4Level: 0
             ]),
        make("bass.digital-rubber", "Digital Rubber", .bass,
             "Elastic FM bass attack for short repeating patterns.", [
                .algorithm: 0, .outputGain: 0.76, .feedback: 0.12,
                .op1Ratio: 0.5, .op1Level: 0.87,
                .op1Decay: 0.19, .op1Sustain: 0.46, .op1Release: 0.08,
                .op2Ratio: 2, .op2Level: 0.69, .op2Decay: 0.08, .op2Sustain: 0.03,
                .op3Ratio: 5, .op3Level: 0.23, .op3Decay: 0.05, .op3Sustain: 0,
                .op4Ratio: 7.5, .op4Level: 0.12, .op4Decay: 0.08, .op4Sustain: 0
             ]),
        make("bass.octave-circuit", "Octave Circuit", .bass,
             "Parallel sub and upper harmonics with a steady sustain.", [
                .algorithm: 3, .outputGain: 0.92,
                .op1Ratio: 0.5, .op1Level: 1, .op1Sustain: 0.93,
                .op2Ratio: 1, .op2Level: 0.46, .op2Sustain: 0.78,
                .op3Ratio: 2, .op3Level: 0.19, .op3Sustain: 0.50,
                .op4Ratio: 3, .op4Level: 0.09, .op4Sustain: 0.33,
                .op1Release: 0.18, .op2Release: 0.18,
                .op3Release: 0.18, .op4Release: 0.18
             ]),

        // Leads: sustained carriers, modulation held by the upper operators.
        make("lead.neon-solo", "Neon Solo", .lead,
             "Focused overtone-rich solo lead with subtle feedback.", [
                .algorithm: 0, .outputGain: 0.72, .feedback: 0.12,
                .op1Level: 0.92, .op1Sustain: 0.93,
                .op2Ratio: 2, .op2Level: 0.47, .op2Sustain: 0.72,
                .op3Ratio: 3, .op3Level: 0.20, .op3Sustain: 0.58,
                .op4Level: 0
             ]),
        make("lead.hollow-signal", "Hollow Signal", .lead,
             "Clear nasal lead built from paired FM voices.", [
                .algorithm: 1, .outputGain: 0.78,
                .op1Ratio: 1, .op1Level: 0.88, .op1Sustain: 0.87,
                .op2Ratio: 3.0, .op2Level: 0.55, .op2Sustain: 0.71,
                .op3Ratio: 1, .op3Level: 0.41, .op3Sustain: 0.76,
                .op4Ratio: 2, .op4Level: 0.25, .op4Sustain: 0.69
             ]),
        make("lead.cobalt-edge", "Cobalt Edge", .lead,
             "Aggressive upper harmonic voice for modern digital leads.", [
                .algorithm: 2, .outputGain: 0.7,
                .op1Level: 0.87, .op1Sustain: 0.78,
                .op2Ratio: 2, .op2Level: 0.65, .op2Sustain: 0.69,
                .op3Ratio: 5, .op3Level: 0.34, .op3Sustain: 0.36,
                .op4Ratio: 7, .op4Level: 0.18, .op4Sustain: 0.20
             ]),
        make("lead.lyric-glass", "Lyric Glass", .lead,
             "Lyrical sine-led melody with a gentle bell-like sheen.", [
                .algorithm: 1, .outputGain: 0.82,
                .op1Level: 0.92, .op1Attack: 0.027, .op1Sustain: 0.90,
                .op1Release: 0.4,
                .op2Ratio: 2, .op2Level: 0.23, .op2Decay: 0.48,
                .op2Sustain: 0.21,
                .op3Ratio: 2, .op3Level: 0.25, .op3Sustain: 0.66,
                .op4Level: 0
             ]),

        // Pads: slow operator-envelope evolution, dynamic modulation.
        make("pad.lunar-choir", "Lunar Choir", .pad,
             "Slow smooth harmonics for sustained cinematic chords.", [
                .algorithm: 1, .outputGain: 0.72,
                .op1Level: 0.87, .op1Attack: 1.6, .op1Sustain: 0.86,
                .op1Release: 4.6,
                .op2Ratio: 2, .op2Level: 0.22, .op2Attack: 2.4,
                .op2Sustain: 0.46, .op2Release: 4.1,
                .op3Ratio: 1, .op3Level: 0.32, .op3Attack: 2.1,
                .op3Sustain: 0.81, .op3Release: 5.0,
                .op4Level: 0
             ]),
        make("pad.glacier-light", "Glacier Light", .pad,
             "Slow, crystalline pad with upper harmonics emerging after attack.", [
                .algorithm: 2, .outputGain: 0.69,
                .op1Level: 0.81, .op1Attack: 1.3, .op1Sustain: 0.77,
                .op1Release: 4.7,
                .op2Ratio: 2, .op2Level: 0.35, .op2Attack: 3.1,
                .op2Sustain: 0.47, .op2Release: 3.2,
                .op3Ratio: 4, .op3Level: 0.24, .op3Attack: 2.2,
                .op3Sustain: 0.58, .op3Release: 4.3,
                .op4Ratio: 5.5, .op4Level: 0.09, .op4Attack: 2.7,
                .op4Sustain: 0.26, .op4Release: 3.1
             ]),
        make("pad.deep-atmosphere", "Deep Atmosphere", .pad,
             "Low, warm pad for orchestral underscoring.", [
                .algorithm: 1, .outputGain: 0.77,
                .op1Ratio: 0.5, .op1Level: 0.88, .op1Attack: 2.0,
                .op1Sustain: 0.92, .op1Release: 6.2,
                .op2Ratio: 1, .op2Level: 0.17, .op2Attack: 2.4,
                .op2Sustain: 0.56, .op2Release: 4.8,
                .op3Ratio: 1, .op3Level: 0.35, .op3Attack: 1.7,
                .op3Sustain: 0.88, .op3Release: 5.7,
                .op4Level: 0
             ]),
        make("pad.harmonic-cloud", "Harmonic Cloud", .pad,
             "Shimmering layered harmonics, softly breathing on long notes.", [
                .algorithm: 3, .outputGain: 0.94,
                .op1Ratio: 1, .op1Level: 0.95, .op1Attack: 1.0,
                .op1Sustain: 0.87, .op1Release: 4.2,
                .op2Ratio: 2, .op2Level: 0.45, .op2Attack: 1.7,
                .op2Sustain: 0.62, .op2Release: 4.5,
                .op3Ratio: 3.01, .op3Level: 0.29, .op3Attack: 2.6,
                .op3Sustain: 0.54, .op3Release: 4.9,
                .op4Ratio: 4.02, .op4Level: 0.19, .op4Attack: 3.2,
                .op4Sustain: 0.44, .op4Release: 5.0
             ]),

        // Percussion: punchy initial modulation, short decaying output.
        make("percussion.steel-strike", "Steel Strike", .percussion,
             "A sharp inharmonic struck metal attack.", [
                .algorithm: 2, .outputGain: 0.75, .feedback: 0.12,
                .op1Level: 0.84, .op1Decay: 0.38, .op1Sustain: 0,
                .op1Release: 0.08,
                .op2Ratio: 3.71, .op2Level: 0.90, .op2Decay: 0.04, .op2Sustain: 0,
                .op3Ratio: 6.5, .op3Level: 0.52, .op3Decay: 0.03, .op3Sustain: 0,
                .op4Ratio: 11.8, .op4Level: 0.25, .op4Decay: 0.025, .op4Sustain: 0
             ]),
        make("percussion.digital-wood", "Digital Wood", .percussion,
             "Very short woody knock for rhythmic sound design.", [
                .algorithm: 0, .outputGain: 0.88,
                .op1Level: 0.94, .op1Decay: 0.09, .op1Sustain: 0,
                .op1Release: 0.03,
                .op2Ratio: 1.91, .op2Level: 0.61, .op2Decay: 0.018, .op2Sustain: 0,
                .op3Level: 0, .op4Level: 0
             ]),
        make("percussion.glass-tick", "Glass Tick", .percussion,
             "Sharp, high glass tap with a tiny shimmering tail.", [
                .algorithm: 1, .outputGain: 0.84,
                .op1Ratio: 2.0, .op1Level: 0.76, .op1Decay: 0.16,
                .op1Sustain: 0, .op1Release: 0.08,
                .op2Ratio: 7.32, .op2Level: 0.58, .op2Decay: 0.022, .op2Sustain: 0,
                .op3Ratio: 5.0, .op3Level: 0.20, .op3Decay: 0.12, .op3Sustain: 0,
                .op4Ratio: 9.12, .op4Level: 0.16, .op4Decay: 0.025, .op4Sustain: 0
             ]),
        make("percussion.machine-pulse", "Machine Pulse", .percussion,
             "Compact synthetic percussion with a crunchy digital overtone.", [
                .algorithm: 0, .outputGain: 0.82, .feedback: 0.58,
                .op1Ratio: 0.5, .op1Level: 0.82,
                .op1Decay: 0.21, .op1Sustain: 0, .op1Release: 0.08,
                .op2Ratio: 3.5, .op2Level: 0.86, .op2Decay: 0.035, .op2Sustain: 0,
                .op3Ratio: 8.2, .op3Level: 0.39, .op3Decay: 0.031, .op3Sustain: 0,
                .op4Ratio: 13.1, .op4Level: 0.31, .op4Decay: 0.025, .op4Sustain: 0
             ]),

        // Evolving spectral textures: long attacks, inharmonic ratios,
        // operator envelopes that develop at different rates.
        make("texture.nebula-veil", "Nebula Veil", .texture,
             "A slowly opening, shimmering wash for ambient scoring.", [
                .algorithm: 2, .outputGain: 0.66,
                .op1Ratio: 0.5, .op1Level: 0.89,
                .op1Attack: 2.6, .op1Sustain: 0.87, .op1Release: 7.0,
                .op2Ratio: 1.6, .op2Level: 0.47, .op2Attack: 3.8,
                .op2Sustain: 0.64, .op2Release: 4.7,
                .op3Ratio: 3.7, .op3Level: 0.23, .op3Attack: 5.5,
                .op3Sustain: 0.54, .op3Release: 5.1,
                .op4Ratio: 7.2, .op4Level: 0.13, .op4Attack: 6.3,
                .op4Sustain: 0.33, .op4Release: 6.7
             ]),
        make("texture.rust-horizon", "Rust Horizon", .texture,
             "Uneven metallic harmonics that slowly emerge and recede.", [
                .algorithm: 0, .outputGain: 0.65, .feedback: 0.26,
                .op1Level: 0.78, .op1Attack: 1.9, .op1Sustain: 0.81,
                .op1Release: 6.0,
                .op2Ratio: 1.37, .op2Level: 0.47, .op2Attack: 3.4,
                .op2Sustain: 0.51, .op2Release: 4.0,
                .op3Ratio: 3.12, .op3Level: 0.31, .op3Attack: 4.1,
                .op3Sustain: 0.42, .op3Release: 6.4,
                .op4Ratio: 7.75, .op4Level: 0.21, .op4Attack: 5.0,
                .op4Sustain: 0.30, .op4Release: 4.8
             ]),
        make("texture.frozen-orbit", "Frozen Orbit", .texture,
             "A cold, spatial-feeling harmonic cluster with drifting intervals.", [
                .algorithm: 3, .outputGain: 0.91,
                .op1Ratio: 0.5, .op1Level: 0.91, .op1Attack: 2.8,
                .op1Sustain: 0.86, .op1Release: 7.2,
                .op2Ratio: 1.07, .op2Level: 0.44, .op2Attack: 3.7,
                .op2Sustain: 0.65, .op2Release: 6.7,
                .op3Ratio: 2.03, .op3Level: 0.34, .op3Attack: 4.3,
                .op3Sustain: 0.58, .op3Release: 6.9,
                .op4Ratio: 3.17, .op4Level: 0.24, .op4Attack: 5.9,
                .op4Sustain: 0.46, .op4Release: 7.8
             ]),
        make("texture.chromatic-drift", "Chromatic Drift", .texture,
             "Slow glassy harmonic movement with a bright distant edge.", [
                .algorithm: 1, .outputGain: 0.78,
                .op1Ratio: 1, .op1Level: 0.80, .op1Attack: 2.1,
                .op1Sustain: 0.82, .op1Release: 5.8,
                .op2Ratio: 1.52, .op2Level: 0.39, .op2Attack: 3.7,
                .op2Sustain: 0.52, .op2Release: 4.3,
                .op3Ratio: 2.7, .op3Level: 0.37, .op3Attack: 3.5,
                .op3Sustain: 0.75, .op3Release: 6.2,
                .op4Ratio: 4.13, .op4Level: 0.25, .op4Attack: 5.1,
                .op4Sustain: 0.44, .op4Release: 4.8
             ])
    ]
}

/// Individual damaged user presets are skipped without hiding the valid ones.
public struct StudioFMPresetLoadResult {
    public let presets: [StudioFMPreset]
    public let skippedFiles: [String]
}

/// Native JSON user library stored separately from project files.
/// Only UI/control code reads or writes disk, never the real-time audio thread.
public struct StudioFMPresetStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            self.directory = support
                .appendingPathComponent("Garritan Studio", isDirectory: true)
                .appendingPathComponent("Studio FM Presets", isDirectory: true)
        }
    }

    private func url(forID id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else {
            throw StudioFMPresetError.invalidIdentifier
        }
        return directory.appendingPathComponent(
            uuid.uuidString.lowercased() + ".studiofm.json", isDirectory: false)
    }

    public func loadUserPresets() throws -> StudioFMPresetLoadResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else {
            return StudioFMPresetLoadResult(presets: [], skippedFiles: [])
        }
        let urls = try manager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])
        var presets: [StudioFMPreset] = []
        var skipped: [String] = []
        for url in urls where url.lastPathComponent.hasSuffix(".studiofm.json") {
            do {
                let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard metadata.isRegularFile == true,
                      (metadata.fileSize ?? 1_048_577) <= 1_048_576 else {
                    throw StudioFMPresetError.invalidPreset
                }
                let contents = try Data(contentsOf: url)
                let preset = try JSONDecoder().decode(StudioFMPreset.self, from: contents)
                try preset.validate()
                guard preset.origin == .user,
                      url.standardizedFileURL ==
                        (try self.url(forID: preset.id)).standardizedFileURL else {
                    throw StudioFMPresetError.invalidPreset
                }
                presets.append(preset)
            } catch {
                skipped.append(url.lastPathComponent)
            }
        }
        return StudioFMPresetLoadResult(
            presets: presets.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            skippedFiles: skipped.sorted()
        )
    }

    @discardableResult
    public func save(name: String, summary: String, category: StudioFMPresetCategory,
                     patch: StudioFMPatch) throws -> StudioFMPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.count <= 80 else {
            throw StudioFMPresetError.invalidName
        }
        let preset = StudioFMPreset(
            id: UUID().uuidString.lowercased(), origin: .user,
            name: name, summary: String(summary.prefix(240)), category: category,
            patch: patch
        )
        try preset.validate()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: url(forID: preset.id), options: .atomic)
        return preset
    }

    public func delete(_ preset: StudioFMPreset) throws {
        guard preset.origin == .user else { throw StudioFMPresetError.factoryReadOnly }
        try FileManager.default.removeItem(at: url(forID: preset.id))
    }
}
