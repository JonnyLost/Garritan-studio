import Foundation

/// The shared instrument's source-module IDs. These are stable project/preset
/// identities, not a renumbering of existing Studio Analog or FM parameters.
/// Future engines are appended as their renderers become available.
public enum StudioSynthEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case analog
    case fm
    case wavetable

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .analog: return "Analog"
        case .fm: return "FM"
        case .wavetable: return "Wavetable"
        }
    }
}

/// Each layer is a fully independent native voice engine. No audio pointers,
/// plug-in identities, or audio-thread state are persisted in a project.
public struct StudioSynthLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var engine: StudioSynthEngine
    public var name: String
    public var enabled: Bool
    public var gain: Float
    public var pan: Float
    public var analogPatch: StudioAnalogPatch?
    public var fmPatch: StudioFMPatch?
    public var wavetablePatch: StudioWavetablePatch?

    public init(id: UUID = UUID(), engine: StudioSynthEngine,
                name: String? = nil, enabled: Bool = true,
                gain: Float = 0.5, pan: Float = 0,
                analogPatch: StudioAnalogPatch? = nil,
                fmPatch: StudioFMPatch? = nil,
                wavetablePatch: StudioWavetablePatch? = nil) {
        self.id = id
        self.engine = engine
        self.name = name ?? engine.title
        self.enabled = enabled
        self.gain = gain
        self.pan = pan
        self.analogPatch = analogPatch
        self.fmPatch = fmPatch
        self.wavetablePatch = wavetablePatch
    }

    public func validate() -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80,
              gain.isFinite, (0...1).contains(gain),
              pan.isFinite, (-1...1).contains(pan) else { return false }
        switch engine {
        case .analog:
            guard let patch = analogPatch else { return true }
            return (1...2).contains(patch.version) &&
                patch.values.allSatisfy { key, value in
                    guard let id = Int32(key),
                          let parameter = StudioAnalogParameter(rawValue: id) else {
                        return false
                    }
                    return parameter.valid(value)
                } &&
                (patch.connections == nil ||
                 StudioAnalogConnection.preliminarilyValid(patch.connections!))
        case .fm:
            return fmPatch?.validate() ?? true
        case .wavetable:
            return wavetablePatch?.validate() ?? true
        }
    }
}

/// Versioned Studio Synth sound, embedded directly in a Track. Original
/// StudioAnalogPatch and StudioFMPatch JSON formats remain unchanged.
public struct StudioSynthPatch: Codable, Equatable, Sendable {
    public var version: Int
    public var layers: [StudioSynthLayer]
    /// Optional to preserve every original Studio Synth project file.
    public var modulation: StudioSynthModulationSettings?
    /// MIDI Learn assignments contain only MIDI CC numbers and native targets.
    /// Missing keys in older project JSON decode as nil without migration.
    public var midiControls: StudioSynthMIDIControlSettings?

    public init(version: Int = 1, layers: [StudioSynthLayer] = [
        StudioSynthLayer(engine: .analog, name: "Analog Foundation"),
        StudioSynthLayer(engine: .fm, name: "FM Attack")
    ], modulation: StudioSynthModulationSettings? = nil,
       midiControls: StudioSynthMIDIControlSettings? = nil) {
        self.version = version
        self.layers = layers
        self.modulation = modulation
        self.midiControls = midiControls
    }

    public static func individual(_ engine: StudioSynthEngine) -> StudioSynthPatch {
        StudioSynthPatch(layers: [StudioSynthLayer(engine: engine, gain: 0.75)])
    }

    public var isHybrid: Bool { layers.filter(\.enabled).count > 1 }

    public func validate() -> Bool {
        guard version == 1, (1...4).contains(layers.count),
              layers.contains(where: \.enabled),
              Set(layers.map(\.id)).count == layers.count else { return false }
        return layers.allSatisfy { $0.validate() } &&
            (modulation?.validate(layers: layers) ?? true) &&
            (midiControls?.validate(layers: layers) ?? true)
    }
}
