import Foundation

/// A portable Studio-owned preset. The payload includes the complete native
/// parameter overrides and, where present, the modular cable layout.
/// Presets never store third-party Audio Unit state.
public struct StudioAnalogPreset: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case factory, user
    }

    public let id: String
    public let origin: Origin
    public var name: String
    public var summary: String
    public var category: StudioAnalogPresetCategory
    public var patch: StudioAnalogPatch

    public init(id: String, origin: Origin, name: String, summary: String,
                category: StudioAnalogPresetCategory, patch: StudioAnalogPatch) {
        self.id = id
        self.origin = origin
        self.name = name
        self.summary = summary
        self.category = category
        self.patch = patch
    }

    /// Prevent malformed or unsupported future-format preset files from
    /// entering project state or synthesizer parameters.
    public func validate() throws {
        guard patch.version >= 1 && patch.version <= 2,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, summary.count <= 240,
              patch.values.allSatisfy({ key, value in
                  guard let raw = Int32(key),
                        let parameter = StudioAnalogParameter(rawValue: raw) else {
                      return false
                  }
                  return parameter.valid(value)
              }),
              StudioAnalogConnection.preliminarilyValid(patch.activeConnections) else {
            throw StudioAnalogPresetError.invalidPreset
        }
        switch origin {
        case .factory:
            guard id.hasPrefix("factory.") else { throw StudioAnalogPresetError.invalidPreset }
        case .user:
            guard UUID(uuidString: id) != nil else { throw StudioAnalogPresetError.invalidPreset }
        }
    }
}

public enum StudioAnalogPresetCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case bass, lead, pad, keys, pluck, texture
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum StudioAnalogPresetError: Error, LocalizedError {
    case invalidPreset
    case invalidName
    case factoryReadOnly
    case invalidIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidPreset: return "That Studio Analog preset has invalid or unsupported data."
        case .invalidName: return "Enter a preset name between 1 and 80 characters."
        case .factoryReadOnly: return "Factory presets cannot be deleted or overwritten."
        case .invalidIdentifier: return "That saved preset identifier is invalid."
        }
    }
}

public enum StudioAnalogFactoryLibrary {
    private static func make(_ id: String, _ name: String, _ category: StudioAnalogPresetCategory,
                             _ description: String,
                             _ parameters: [StudioAnalogParameter: Float],
                             connections: [StudioAnalogConnection]? = nil) -> StudioAnalogPreset {
        var patch = StudioAnalogPatch()
        for (parameter, value) in parameters { patch.set(value, for: parameter) }
        patch.connections = connections
        return StudioAnalogPreset(id: "factory." + id, origin: .factory, name: name,
                                  summary: description, category: category, patch: patch)
    }

    /// Original synthesis recipes authored specifically for the native DSP.
    /// No samples, licensed waveforms, or third-party content are embedded.
    public static let presets: [StudioAnalogPreset] = [
        // Bass
        make("bass.sub-foundation", "Sub Foundation", .bass, "Round sine sub with a clean, short envelope.", [
            .oscillator1Wave: 0, .oscillator2Wave: 0, .oscillator1Level: 0.86,
            .oscillator2Level: 0.20, .oscillator2Semitones: -12,
            .filterCutoff: 1400, .resonance: 0.05, .filterEnvelopeDepth: 0.05,
            .amplitudeDecay: 0.22, .amplitudeSustain: 0.78, .amplitudeRelease: 0.14
        ]),
        make("bass.pulse-driver", "Pulse Driver", .bass, "Punchy dual-pulse bass for rhythmic sequences.", [
            .oscillator1Wave: 3, .oscillator2Wave: 3, .pulseWidth: 0.30,
            .oscillator1Level: 0.64, .oscillator2Level: 0.28,
            .oscillator2Semitones: -12, .filterCutoff: 320,
            .resonance: 0.34, .filterEnvelopeDepth: 0.68,
            .filterDecay: 0.22, .filterSustain: 0.04,
            .amplitudeDecay: 0.18, .amplitudeSustain: 0.70
        ]),
        make("bass.acid-walk", "Acid Walk", .bass, "Resonant saw bass with percussive filter movement.", [
            .oscillator1Wave: 2, .oscillator2Wave: 2, .oscillator2Level: 0.16,
            .filterCutoff: 260, .resonance: 0.82, .filterEnvelopeDepth: 0.90,
            .filterAttack: 0.002, .filterDecay: 0.16, .filterSustain: 0.06,
            .amplitudeAttack: 0.002, .amplitudeRelease: 0.10
        ]),
        make("bass.deep-reese", "Deep Reese", .bass, "Wide detuned-octave pulse and saw blend.", [
            .oscillator1Wave: 2, .oscillator2Wave: 3, .oscillator1Level: 0.64,
            .oscillator2Level: 0.44, .oscillator2Semitones: -0.18,
            .filterCutoff: 1050, .resonance: 0.22, .filterEnvelopeDepth: 0.28,
            .amplitudeRelease: 0.36, .lfoRate: 0.42, .lfoDepth: 0.12
        ]),
        // Lead
        make("lead.classic-saw", "Classic Saw Lead", .lead, "Forward, bright two-oscillator solo lead.", [
            .oscillator1Wave: 2, .oscillator2Wave: 2, .oscillator2Semitones: 0.08,
            .filterCutoff: 6400, .resonance: 0.12, .amplitudeSustain: 0.92,
            .amplitudeRelease: 0.12, .modulationDepth: 0.35
        ]),
        make("lead.pulse-solo", "Pulse Solo", .lead, "Hollow singing lead with expressive vibrato.", [
            .oscillator1Wave: 3, .oscillator2Wave: 3, .pulseWidth: 0.24,
            .oscillator2Semitones: 0.06, .filterCutoff: 4200,
            .amplitudeAttack: 0.014, .amplitudeRelease: 0.22,
            .lfoRate: 5.2, .modulationDepth: 0.6
        ]),
        make("lead.fifth-horizon", "Fifth Horizon", .lead, "Open fifth harmonics above a firm lead core.", [
            .oscillator1Wave: 2, .oscillator2Wave: 1, .oscillator2Semitones: 7,
            .oscillator1Level: 0.57, .oscillator2Level: 0.33,
            .filterCutoff: 8200, .filterEnvelopeDepth: 0.16,
            .amplitudeSustain: 0.84, .amplitudeRelease: 0.22
        ]),
        make("lead.mellow-mono", "Mellow Solo", .lead, "Soft triangle/saw timbre for lyrical melodic lines.", [
            .oscillator1Wave: 1, .oscillator2Wave: 2, .oscillator1Level: 0.58,
            .oscillator2Level: 0.17, .filterCutoff: 1900,
            .filterAttack: 0.035, .filterDecay: 0.36,
            .amplitudeAttack: 0.03, .amplitudeRelease: 0.38
        ]),
        // Pads
        make("pad.warm-strings", "Warm Strings", .pad, "Slow dual-saw bloom with a gentle release.", [
            .oscillator1Wave: 2, .oscillator2Wave: 2, .oscillator2Semitones: 0.12,
            .filterCutoff: 2800, .resonance: 0.17, .filterEnvelopeDepth: 0.34,
            .filterAttack: 1.2, .filterRelease: 2.3,
            .amplitudeAttack: 0.9, .amplitudeRelease: 2.8, .amplitudeSustain: 0.83
        ]),
        make("pad.air-bloom", "Air Bloom", .pad, "Soft triangle wash with a trace of filtered noise.", [
            .oscillator1Wave: 1, .oscillator2Wave: 1, .noiseLevel: 0.13,
            .filterCutoff: 5100, .resonance: 0.10, .filterAttack: 2.6,
            .amplitudeAttack: 1.65, .amplitudeRelease: 4.2,
            .lfoRate: 0.25, .lfoDepth: 0.15
        ]),
        make("pad.slow-brass", "Slow Brass", .pad, "Rounded swell with a broad filter envelope.", [
            .oscillator1Wave: 2, .oscillator2Wave: 3,
            .filterCutoff: 1300, .filterEnvelopeDepth: 0.70,
            .filterAttack: 0.75, .filterSustain: 0.72,
            .amplitudeAttack: 0.48, .amplitudeRelease: 1.8
        ]),
        make("pad.luminous-fifths", "Luminous Fifths", .pad, "Shimmering fifth harmonics with gentle modulation.", [
            .oscillator1Wave: 1, .oscillator2Wave: 2, .oscillator2Semitones: 7,
            .filterCutoff: 6100, .resonance: 0.16, .filterEnvelopeDepth: 0.36,
            .amplitudeAttack: 1.2, .amplitudeRelease: 3.5,
            .lfoRate: 0.4, .lfoDepth: 0.18
        ]),
        // Keys
        make("keys.analog-ep", "Analog Electric Keys", .keys, "Rounded short attack and warm decay.", [
            .oscillator1Wave: 1, .oscillator2Wave: 0, .oscillator2Semitones: 12,
            .oscillator1Level: 0.60, .oscillator2Level: 0.23,
            .filterCutoff: 2800, .filterEnvelopeDepth: 0.38,
            .amplitudeDecay: 0.7, .amplitudeSustain: 0.32, .amplitudeRelease: 0.42
        ]),
        make("keys.dusty-keys", "Dusty Keys", .keys, "Soft pulse keyboard tone with a hint of air.", [
            .oscillator1Wave: 3, .oscillator2Wave: 1, .pulseWidth: 0.42,
            .noiseLevel: 0.04, .filterCutoff: 1600,
            .filterDecay: 0.3, .amplitudeDecay: 0.52,
            .amplitudeSustain: 0.28, .amplitudeRelease: 0.65
        ]),
        make("keys.glass-organ", "Glass Organ", .keys, "Stable overtone stack with minimal filter motion.", [
            .oscillator1Wave: 0, .oscillator2Wave: 0, .oscillator2Semitones: 12,
            .oscillator1Level: 0.67, .oscillator2Level: 0.38,
            .filterCutoff: 12000, .filterEnvelopeDepth: 0.0,
            .amplitudeSustain: 1.0, .amplitudeDecay: 0.09,
            .amplitudeRelease: 0.21
        ]),
        make("keys.vintage-square", "Vintage Square Keys", .keys, "Classic hollow keyboard tone with gentle filtering.", [
            .oscillator1Wave: 3, .oscillator2Wave: 3, .pulseWidth: 0.5,
            .oscillator2Semitones: 12, .oscillator2Level: 0.17,
            .filterCutoff: 2200, .amplitudeDecay: 0.43,
            .amplitudeSustain: 0.58, .amplitudeRelease: 0.24
        ]),
        // Plucks
        make("pluck.copper-pluck", "Copper Pluck", .pluck, "Bright fast transient and rapid rolloff.", [
            .oscillator1Wave: 2, .oscillator2Wave: 1, .filterCutoff: 1050,
            .filterEnvelopeDepth: 0.94, .filterAttack: 0.001,
            .filterDecay: 0.13, .filterSustain: 0,
            .amplitudeAttack: 0.001, .amplitudeDecay: 0.20,
            .amplitudeSustain: 0, .amplitudeRelease: 0.09
        ]),
        make("pluck.wooden-click", "Wooden Click", .pluck, "Dark, woody pulse pluck for ostinatos.", [
            .oscillator1Wave: 3, .oscillator2Wave: 1,
            .pulseWidth: 0.32, .filterCutoff: 530,
            .filterEnvelopeDepth: 0.55, .filterDecay: 0.12,
            .filterSustain: 0.02, .amplitudeDecay: 0.16,
            .amplitudeSustain: 0.0, .amplitudeRelease: 0.07
        ]),
        make("pluck.glass-droplet", "Glass Droplet", .pluck, "Clear bell-like sine pluck with upper overtone.", [
            .oscillator1Wave: 0, .oscillator2Wave: 0, .oscillator2Semitones: 12,
            .oscillator1Level: 0.65, .oscillator2Level: 0.29,
            .filterCutoff: 8500, .filterEnvelopeDepth: 0.1,
            .amplitudeDecay: 0.85, .amplitudeSustain: 0, .amplitudeRelease: 0.28
        ]),
        make("pluck.fifth-pluck", "Fifth Pluck", .pluck, "Bright harmonic fifth with a clipped tail.", [
            .oscillator1Wave: 2, .oscillator2Wave: 1, .oscillator2Semitones: 7,
            .filterCutoff: 2200, .filterEnvelopeDepth: 0.72,
            .filterDecay: 0.18, .filterSustain: 0,
            .amplitudeDecay: 0.34, .amplitudeSustain: 0, .amplitudeRelease: 0.15
        ]),
        // Textures
        make("texture.noise-wash", "Noise Wash", .texture, "Long filtered noise texture for cinematic beds.", [
            .oscillator1Level: 0.05, .oscillator2Level: 0.0, .noiseLevel: 0.86,
            .filterCutoff: 2800, .resonance: 0.15, .filterEnvelopeDepth: 0.3,
            .amplitudeAttack: 2.2, .amplitudeRelease: 4.5,
            .lfoRate: 0.13, .lfoDepth: 0.38
        ]),
        make("texture.rising-fog", "Rising Fog", .texture, "Slow evolving filtered saws and breath.", [
            .oscillator1Wave: 2, .oscillator2Wave: 1, .noiseLevel: 0.16,
            .filterCutoff: 420, .filterEnvelopeDepth: 0.93,
            .filterAttack: 4.0, .filterRelease: 3.2,
            .amplitudeAttack: 2.0, .amplitudeRelease: 3.0
        ]),
        make("texture.hollow-wind", "Hollow Wind", .texture, "Pulse and noise with drifting resonant motion.", [
            .oscillator1Wave: 3, .oscillator1Level: 0.18,
            .oscillator2Level: 0.06, .noiseLevel: 0.50,
            .pulseWidth: 0.20, .filterCutoff: 1150, .resonance: 0.55,
            .lfoRate: 0.22, .lfoDepth: 0.48,
            .amplitudeAttack: 1.0, .amplitudeRelease: 2.7
        ]),
        make("texture.motion-bed", "Motion Bed", .texture, "Slow phasing harmonics with an open tail.", [
            .oscillator1Wave: 2, .oscillator2Wave: 2, .oscillator2Semitones: 0.21,
            .filterCutoff: 3400, .resonance: 0.23, .lfoRate: 0.7,
            .lfoDepth: 0.64, .amplitudeAttack: 1.1,
            .amplitudeRelease: 3.9, .modulationTarget: 1,
            .modulationDepth: 0.35
        ])
    ]
}

/// Loading corrupted files must not prevent the other user presets or factory
/// sounds from appearing. Individual file problems are reported to the UI.
public struct StudioAnalogPresetLoadResult {
    public let presets: [StudioAnalogPreset]
    public let skippedFiles: [String]
}

/// Local user bank, independent of projects. It lives in the user's macOS
/// Application Support directory (not the Git working tree or an AU folder).
/// The directory can be injected for tests. All disk operations are performed
/// by UI/control code; never call from an audio render callback.
public struct StudioAnalogPresetStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            self.directory = support
                .appendingPathComponent("Garritan Studio", isDirectory: true)
                .appendingPathComponent("Studio Analog Presets", isDirectory: true)
        }
    }

    private func url(forID id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else {
            throw StudioAnalogPresetError.invalidIdentifier
        }
        return directory.appendingPathComponent(uuid.uuidString.lowercased() + ".studioanalog.json",
                                                isDirectory: false)
    }

    public func loadUserPresets() throws -> StudioAnalogPresetLoadResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else {
            return StudioAnalogPresetLoadResult(presets: [], skippedFiles: [])
        }
        let urls = try manager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
        var presets: [StudioAnalogPreset] = []
        var skipped: [String] = []
        for url in urls where url.lastPathComponent.hasSuffix(".studioanalog.json") {
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw StudioAnalogPresetError.invalidPreset
                }
                let data = try Data(contentsOf: url)
                guard data.count <= 1_048_576 else { throw StudioAnalogPresetError.invalidPreset }
                let preset = try JSONDecoder().decode(StudioAnalogPreset.self, from: data)
                try preset.validate()
                guard preset.origin == .user,
                      url.standardizedFileURL == (try self.url(forID: preset.id)).standardizedFileURL else {
                    throw StudioAnalogPresetError.invalidPreset
                }
                presets.append(preset)
            } catch {
                skipped.append(url.lastPathComponent)
            }
        }
        return StudioAnalogPresetLoadResult(
            presets: presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            skippedFiles: skipped.sorted()
        )
    }

    @discardableResult
    public func save(name: String, summary: String, category: StudioAnalogPresetCategory,
                     patch: StudioAnalogPatch) throws -> StudioAnalogPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed.count <= 80 else {
            throw StudioAnalogPresetError.invalidName
        }
        let preset = StudioAnalogPreset(
            id: UUID().uuidString.lowercased(), origin: .user, name: trimmed,
            summary: String(summary.prefix(240)), category: category, patch: patch
        )
        try preset.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: url(forID: preset.id), options: .atomic)
        return preset
    }

    public func delete(_ preset: StudioAnalogPreset) throws {
        guard preset.origin == .user else { throw StudioAnalogPresetError.factoryReadOnly }
        try FileManager.default.removeItem(at: url(forID: preset.id))
    }
}
