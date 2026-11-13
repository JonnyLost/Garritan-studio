import Foundation

/// An owned-sample reference for Studio's native sampler. Sample data is not
/// embedded in the track JSON; a future portable .studioinstrument package
/// and security-scoped file bookmarks will replace the absolute file path.
public struct StudioSamplerZone: Codable, Equatable, Sendable {
    public var filePath: String
    /// Stable app-owned recording filename; optional for older projects and
    /// samples intentionally stored outside the managed library.
    public var managedFileName: String?
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
    /// 0...7 selects an alternate recorded take within the same velocity layer.
    public var roundRobinIndex: UInt8?
    /// Release triggers play on MIDI note-off, independently of the note-on sample.
    public var isReleaseTrigger: Bool?
    /// 0...3 identifies a coherent recorded microphone position. Unset is main mic.
    public var microphoneID: UInt8?
    /// Target rootNote identifies the destination pitch. If present, this
    /// one-shot recording is played ONLY on overlapping from→target legato.
    public var legatoFromNote: UInt8?

    public var hasSustainLoop: Bool {
        loopStartFrame != nil && loopEndFrame != nil
    }

    public init(sampleURL: URL, rootNote: UInt8 = 60,
                lowestNote: UInt8 = 0, highestNote: UInt8 = 127,
                lowestVelocity: UInt8 = 1, highestVelocity: UInt8 = 127) {
        self.filePath = sampleURL.path
        self.managedFileName = StudioSamplerSampleLibrary.managedName(for: sampleURL)
        self.rootNote = rootNote
        self.lowestNote = lowestNote
        self.highestNote = highestNote
        self.lowestVelocity = lowestVelocity
        self.highestVelocity = highestVelocity
    }

    public var isValid: Bool {
        rootNote <= 127 && lowestNote <= highestNote && highestNote <= 127 &&
        lowestVelocity >= 1 && lowestVelocity <= highestVelocity &&
        highestVelocity <= 127 && !filePath.isEmpty &&
        (managedFileName == nil ||
         StudioSamplerSampleLibrary.validManagedFileName(managedFileName!)) &&
        validLoop && validTrim &&
        (articulationID ?? 0) <= 15 && (roundRobinIndex ?? 0) < 8 &&
        (isReleaseTrigger != true || !hasSustainLoop) &&
        (microphoneID ?? 0) < 4 &&
        (legatoFromNote == nil || (legatoFromNote! <= 127 &&
            legatoFromNote! != rootNote && !hasSustainLoop &&
            isReleaseTrigger != true)) && validFades
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

    public var sampleURL: URL {
        if let name = managedFileName,
           let url = try? StudioSamplerSampleLibrary.managedURL(forFileName: name) {
            return url
        }
        return URL(fileURLWithPath: filePath)
    }
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

/// A coherent microphone set is selected at note-on. Gain/pan may change
/// while held notes sound; sample waveforms are never modified.
public struct StudioSamplerMicrophone: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt8
    public var name: String
    public var gain: Float
    public var pan: Float
    public var isMuted: Bool

    public init(id: UInt8, name: String, gain: Float = 1,
                pan: Float = 0, isMuted: Bool = false) {
        self.id = id
        self.name = name
        self.gain = gain
        self.pan = pan
        self.isMuted = isMuted
    }

    public var isValid: Bool {
        id < 4 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.count <= 48 && gain.isFinite && (0...2).contains(gain) &&
        pan.isFinite && (-1...1).contains(pan)
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
    /// Optional legacy-safe controls; 0 vibrato, 127 full breath by default.
    public var vibratoCC21: UInt8?
    public var breathCC2: UInt8?
    /// Legato only acts when a second pitch overlaps a held note on its channel.
    public var legatoEnabled: Bool?
    /// Outgoing and incoming sustain crossfade, even when no transition exists.
    public var legatoCrossfadeMilliseconds: Float?
    public var microphones: [StudioSamplerMicrophone]?

    public var presentation: StudioSamplerInstrumentKind { instrumentKind ?? .general }
    /// An empty sampler remains a saved instrument choice while the user
    /// builds a mapping. No audio node is created until samples are added.
    public var isEmpty: Bool { zones.isEmpty }

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
        (envelope?.isValid ?? true) &&
        (legatoCrossfadeMilliseconds == nil ||
         (legatoCrossfadeMilliseconds!.isFinite &&
          (5...250).contains(legatoCrossfadeMilliseconds!))) &&
        validMicrophones && validArticulations
    }

    public var validMicrophones: Bool {
        let groups = microphones ?? []
        return groups.count <= 4 && groups.allSatisfy(\.isValid) &&
            Set(groups.map(\.id)).count == groups.count &&
            zones.allSatisfy { zone in
                (zone.microphoneID ?? 0) == 0 ||
                    groups.contains(where: { $0.id == zone.microphoneID })
            }
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
