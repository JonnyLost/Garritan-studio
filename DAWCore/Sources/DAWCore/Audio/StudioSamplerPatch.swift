import Foundation

/// An owned-sample reference for Studio's native sampler. Sample data is not
/// embedded in the track JSON; a future portable .studioinstrument package
/// and security-scoped file bookmarks will replace the absolute file path.
public struct StudioSamplerZone: Codable, Equatable, Sendable {
    public var filePath: String
    public var rootNote: UInt8
    public var lowestNote: UInt8
    public var highestNote: UInt8
    public var lowestVelocity: UInt8
    public var highestVelocity: UInt8
    /// Offsets in source sample frames, end exclusive. Nil means one-shot.
    public var loopStartFrame: UInt32?
    public var loopEndFrame: UInt32?
    public var loopCrossfadeFrames: UInt32?
    /// Source-frame playback bounds; nil means full source recording.
    public var trimStartFrame: UInt32?
    public var trimEndFrame: UInt32?
    /// Nondestructive gain ramps at the playback-region boundaries.
    public var fadeInFrames: UInt32?
    public var fadeOutFrames: UInt32?
    /// ID 0 is the original/default articulation; 1...15 select others.
    public var articulationID: UInt8?

    public var hasSustainLoop: Bool {
        loopStartFrame != nil && loopEndFrame != nil
    }

    public init(sampleURL: URL, rootNote: UInt8 = 60,
                lowestNote: UInt8 = 0, highestNote: UInt8 = 127,
                lowestVelocity: UInt8 = 1, highestVelocity: UInt8 = 127) {
        self.filePath = sampleURL.path
        self.rootNote = rootNote
        self.lowestNote = lowestNote
        self.highestNote = highestNote
        self.lowestVelocity = lowestVelocity
        self.highestVelocity = highestVelocity
    }

    public var isValid: Bool {
        rootNote <= 127 && lowestNote <= highestNote && highestNote <= 127 &&
        lowestVelocity >= 1 && lowestVelocity <= highestVelocity &&
        highestVelocity <= 127 && !filePath.isEmpty && validLoop && validTrim &&
        (articulationID ?? 0) <= 15 && validFades
    }

    public var validTrim: Bool {
        guard let end = trimEndFrame else {
            return trimStartFrame == nil || trimStartFrame! <= UInt32.max - 2
        }
        let start = trimStartFrame ?? 0
        return end >= 2 && start < end && end - start >= 2
    }

    public var validFades: Bool {
        guard (fadeInFrames ?? 0) <= 10_000_000,
              (fadeOutFrames ?? 0) <= 10_000_000 else { return false }
        if let end = trimEndFrame {
            let length = end - (trimStartFrame ?? 0)
            return UInt64(fadeInFrames ?? 0) + UInt64(fadeOutFrames ?? 0) <= UInt64(length)
        }
        return true
    }

    public var validLoop: Bool {
        guard let start = loopStartFrame, let end = loopEndFrame else {
            return loopStartFrame == nil && loopEndFrame == nil &&
                (loopCrossfadeFrames == nil || loopCrossfadeFrames == 0)
        }
        return start <= end && end - start >= 4 &&
            start >= (trimStartFrame ?? 0) &&
            (trimEndFrame == nil || end <= trimEndFrame!) &&
            (loopCrossfadeFrames ?? 0) <= (end - start) / 2
    }

    public var sampleURL: URL { URL(fileURLWithPath: filePath) }
}

/// A keyswitch is consumed by the sampler on note-on and chooses which
/// recorded sample group will respond to subsequent played notes.
public struct StudioSamplerArticulation: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt8
    public var name: String
    public var keyswitchNote: UInt8

    public init(id: UInt8, name: String, keyswitchNote: UInt8) {
        self.id = id
        self.name = name
        self.keyswitchNote = keyswitchNote
    }

    public var isValid: Bool {
        (1...15).contains(id) && keyswitchNote <= 127 &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 48
    }
}

/// ADSR in seconds and linear sustain gain; optional on old projects.
public struct StudioSamplerEnvelope: Codable, Equatable, Sendable {
    public var attackSeconds: Float
    public var decaySeconds: Float
    public var sustainLevel: Float
    public var releaseSeconds: Float

    public init(attackSeconds: Float = 0.0015,
                decaySeconds: Float = 0,
                sustainLevel: Float = 1,
                releaseSeconds: Float = 0.0015) {
        self.attackSeconds = attackSeconds
        self.decaySeconds = decaySeconds
        self.sustainLevel = sustainLevel
        self.releaseSeconds = releaseSeconds
    }

    public var isValid: Bool {
        attackSeconds.isFinite && (0...30).contains(attackSeconds) &&
        decaySeconds.isFinite && (0...30).contains(decaySeconds) &&
        sustainLevel.isFinite && (0...1).contains(sustainLevel) &&
        releaseSeconds.isFinite && (0...30).contains(releaseSeconds)
    }
}

/// The front-panel layout is a presentation choice: all variants use the
/// same native sampler, sample zones, MIDI dispatch and output routing.
public enum StudioSamplerInstrumentKind: String, CaseIterable, Codable, Sendable {
    case general
    case soloViolin
    case cinematicPercussion
    case choirAndTextures

    public var title: String {
        switch self {
        case .general: return "Studio Sampler"
        case .soloViolin: return "Solo Violin"
        case .cinematicPercussion: return "Cinematic Percussion"
        case .choirAndTextures: return "Choir & Textures"
        }
    }
}

/// Versioned, editable mapping of source audio to MIDI note/velocity ranges.
/// Milestone 1 selects one matching zone per note, favoring the nearest root.
/// Layer blending and streamed sample references will extend this format.
public struct StudioSamplerPatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var zones: [StudioSamplerZone]
    /// Optional for compatibility with all previously saved version-1 patches.
    public var instrumentKind: StudioSamplerInstrumentKind?
    /// When true, CC1 morphs between sample layers with the same root key.
    public var cc1Crossfade: Bool?
    /// Initial MIDI control states, 0...127. Playback CC can override them.
    public var dynamicsCC1: UInt8?
    public var expressionCC11: UInt8?
    /// Applied to new notes without sample data reload or graph rewiring.
    public var envelope: StudioSamplerEnvelope?
    /// Optional user-defined articulation assignments; ID 0 is Default.
    public var articulations: [StudioSamplerArticulation]?
    /// Optional MIDI note to switch back to ID 0 / Default Sustain.
    public var defaultKeyswitchNote: UInt8?
    /// Restored selection when opening the saved instrument.
    public var selectedArticulationID: UInt8?

    public var presentation: StudioSamplerInstrumentKind { instrumentKind ?? .general }

    public init(zones: [StudioSamplerZone]) {
        self.zones = zones
    }

    public init(sampleURL: URL, rootNote: UInt8 = 60) {
        self.zones = [StudioSamplerZone(sampleURL: sampleURL, rootNote: rootNote)]
    }

    public var isValid: Bool {
        version == 1 && !zones.isEmpty && zones.count <= 128 &&
        zones.allSatisfy(\.isValid) &&
        (dynamicsCC1 == nil || dynamicsCC1! <= 127) &&
        (expressionCC11 == nil || expressionCC11! <= 127) &&
        (envelope?.isValid ?? true) && validArticulations
    }

    public var validArticulations: Bool {
        let items = articulations ?? []
        guard items.count <= 15 && items.allSatisfy(\.isValid) &&
              (defaultKeyswitchNote == nil ||
               !items.contains(where: { $0.keyswitchNote == defaultKeyswitchNote })) &&
              Set(items.map(\.id)).count == items.count &&
              Set(items.map(\.keyswitchNote)).count == items.count else { return false }
        let ids = Set(items.map(\.id)).union([0])
        return ids.contains(selectedArticulationID ?? 0) &&
            zones.allSatisfy { ids.contains($0.articulationID ?? 0) }
    }
}
