import Foundation

// MARK: - Studio Sound Designer: offline patch generation

/// The generated sound is an ordinary StudioSynthPatch. No special playback
/// engine, remote service, sample files, or proprietary model is required.
public struct StudioSoundGenerationResult: Equatable, Sendable {
    public let patch: StudioSynthPatch
    public let suggestedName: String
    public let explanation: [String]
    public let limitations: [String]

    public init(patch: StudioSynthPatch, suggestedName: String,
                explanation: [String], limitations: [String]) {
        self.patch = patch
        self.suggestedName = suggestedName
        self.explanation = explanation
        self.limitations = limitations
    }
}

public enum StudioSoundPatchGenerationError: Error, LocalizedError, Equatable {
    case insufficientDescription
    case tooManyEngines
    case noAvailableEngine
    case refinementRequiresExistingSound
    case invalidGeneratedPatch

    public var errorDescription: String? {
        switch self {
        case .insufficientDescription:
            return "Describe the sound's role, character, or synthesis engine."
        case .tooManyEngines:
            return "Studio Hybrid supports up to four simultaneous synthesis engines."
        case .noAvailableEngine:
            return "No native synthesis engine remains after your exclusions."
        case .refinementRequiresExistingSound:
            return "Refining an existing patch is part of the next Sound Designer milestone."
        case .invalidGeneratedPatch:
            return "The generated Synth patch could not be validated."
        }
    }
}

/// Builds bounded and editable Studio Synth/Hybrid sounds by combining native
/// factory patch recipes with validated, parameter-range-aware tone shaping.
///
/// The generator never writes to Project, PlaybackEngine, or the audio graph.
/// Callers may preview the result and then adopt it via the existing track API.
/// It intentionally does not yet revise an existing sound (Milestone 3).
public enum StudioSoundPatchGenerator {
    public static func generate(description: String) throws -> StudioSoundGenerationResult {
        try generate(from: StudioSoundDescriptionInterpreter.interpret(description))
    }

    public static func generate(
        from intent: StudioSoundDescriptionIntent
    ) throws -> StudioSoundGenerationResult {
        guard intent.mode == .create else {
            throw StudioSoundPatchGenerationError.refinementRequiresExistingSound
        }
        guard intent.originalText.count <= StudioSoundDescriptionInterpreter.maximumCharacters,
              intent.role != nil || !intent.families.isEmpty ||
              !intent.engineHints.isEmpty || !intent.instructions.isEmpty else {
            throw StudioSoundPatchGenerationError.insufficientDescription
        }

        let engines = try chooseEngines(for: intent)
        let spread = target(.spaciousness, from: intent) ?? 0.35
        let width: Float = engines.count > 1 ? 0.04 + 0.17 * spread : 0
        let layerLevel: Float
        switch engines.count {
        case 1: layerLevel = 0.70
        case 2: layerLevel = 0.40
        case 3: layerLevel = 0.31
        default: layerLevel = 0.25
        }

        var layers: [StudioSynthLayer] = []
        for (index, engine) in engines.enumerated() {
            let pan: Float = index.isMultiple(of: 2) ? -width : width
            let layer = makeLayer(
                engine, intent: intent, level: layerLevel, pan: pan,
                id: stableUUID(intent.originalText + engine.rawValue, index: index))
            layers.append(layer)
        }

        var modulation: StudioSynthModulationSettings?
        if let movement = target(.movement, from: intent), movement > 0.55 {
            var settings = StudioSynthModulationSettings()
            settings.lfo1Rate = 0.12 + movement * 0.8
            for (index, layer) in layers.prefix(2).enumerated() {
                settings.routes.append(
                    StudioSynthModRoute(
                        id: stableUUID(intent.originalText + "mod", index: index),
                        source: .lfo1, layerID: layer.id,
                        destination: motionDestination(for: layer.engine),
                        depth: 0.08 + movement * 0.22))
            }
            modulation = settings
        }

        let patch = StudioSynthPatch(layers: layers, modulation: modulation)
        guard patch.validate() else {
            throw StudioSoundPatchGenerationError.invalidGeneratedPatch
        }

        let role = intent.role?.rawValue.capitalized ?? "Sound"
        let name = intent.families.first.map { "\($0.rawValue.capitalized) \(role)" }
            ?? "Studio \(role)"
        let explanation = layers.map {
            "\($0.engine.title) — editable native \($0.name.lowercased())"
        }
        var limitations: [String] = []
        if intent.instruction(for: .spaciousness) != nil {
            limitations.append(
                "Spaciousness adjusts layer panning and compatible internal controls; it does not add hall reverb.")
        }
        if intent.instruction(for: .attackTime) != nil && engines.contains(.physical) {
            limitations.append(
                "Physical Modeling has no general amplitude attack envelope; acoustic excitation is adjusted where supported.")
        }

        return StudioSoundGenerationResult(
            patch: patch, suggestedName: String(name.prefix(80)),
            explanation: explanation, limitations: limitations)
    }

    // MARK: Engine selection

    private static func chooseEngines(
        for intent: StudioSoundDescriptionIntent
    ) throws -> [StudioSynthEngine] {
        // Explicit choices are authoritative: never silently discard an
        // explicitly requested fifth engine or add an unrequested substitute.
        let hinted = unique(intent.engineHints.filter {
            !intent.excludedEngines.contains($0)
        })
        if hinted.count > 4 {
            throw StudioSoundPatchGenerationError.tooManyEngines
        }
        if !hinted.isEmpty { return hinted }

        var selected: [StudioSynthEngine]
        if intent.families.contains(.bells) {
            selected = intent.role == .texture ? [.granular, .physical] : [.physical, .fm]
        } else if intent.families.contains(.brass) ||
                    intent.families.contains(.woodwinds) {
            selected = intent.role == .pad ? [.physical, .additive] : [.physical]
        } else if intent.families.contains(.strings) {
            if intent.role == .pad {
                selected = [.analog, .additive]
                if (target(.movement, from: intent) ?? 0) > 0.55 ||
                   (target(.metallicCharacter, from: intent) ?? 0) > 0.55 {
                    selected.append(.wavetable)
                }
            } else {
                selected = [.physical]
            }
        } else if intent.families.contains(.voice) {
            selected = intent.role == .pad ? [.additive, .fm] : [.additive]
        } else {
            switch intent.role {
            case .bass:
                selected = [.analog]
                if (target(.aggression, from: intent) ?? 0) > 0.65 {
                    selected.append(.fm)
                }
            case .lead: selected = [.analog]
            case .pad: selected = [.analog, .wavetable]
            case .keys: selected = [.fm]
            case .pluck, .percussion: selected = [.physical]
            case .texture: selected = [.granular, .wavetable]
            case nil:
                if (target(.metallicCharacter, from: intent) ?? 0) > 0.55 {
                    selected = [.fm, .additive]
                } else if (target(.movement, from: intent) ?? 0) > 0.55 {
                    selected = [.wavetable]
                } else if (target(.lowEnd, from: intent) ?? 0) > 0.55 {
                    selected = [.analog]
                } else {
                    selected = [.analog]
                }
            }
        }

        selected = unique(selected.filter { !intent.excludedEngines.contains($0) })
        // Excluding a family must not force its own characteristic algorithm
        // (e.g. "no bells" does not choose the physical bell model).
        if selected.isEmpty {
            guard let fallback = StudioSynthEngine.allCases.first(where: {
                !intent.excludedEngines.contains($0)
            }) else {
                throw StudioSoundPatchGenerationError.noAvailableEngine
            }
            selected = [fallback]
        }
        return Array(selected.prefix(4))
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Native layer recipes and transformations

    private static func makeLayer(
        _ engine: StudioSynthEngine, intent: StudioSoundDescriptionIntent,
        level: Float, pan: Float, id: UUID
    ) -> StudioSynthLayer {
        switch engine {
        case .analog:
            var sound = analogSeed(intent)
            if let brightness = target(.brightness, from: intent) {
                sound.set(expRange(160, 11_000, brightness), for: .filterCutoff)
            }
            if let warmth = target(.warmth, from: intent) {
                sound.set(0.07 + (1 - warmth) * 0.28, for: .resonance)
            }
            if let attack = target(.attackTime, from: intent) {
                sound.set(expRange(0.002, 5, attack), for: .amplitudeAttack)
            }
            if let release = target(.releaseTime, from: intent) {
                sound.set(expRange(0.03, 8, release), for: .amplitudeRelease)
            }
            if let movement = target(.movement, from: intent) {
                sound.set(0.65 * movement, for: .lfoDepth)
                sound.set(0.13 + movement * 1.5, for: .lfoRate)
            }
            if let metal = target(.metallicCharacter, from: intent) {
                sound.set(0.10 + 0.52 * metal, for: .resonance)
            }
            if let noise = target(.noise, from: intent) {
                sound.set(0.42 * noise, for: .noiseLevel)
            }
            if let low = target(.lowEnd, from: intent) {
                sound.set(low > 0.6 ? -12 : 0, for: .oscillator2Semitones)
            }
            if let aggression = target(.aggression, from: intent) {
                sound.set(0.15 + aggression * 0.65, for: .filterEnvelopeDepth)
            }
            return StudioSynthLayer(
                id: id, engine: .analog, name: "Analog Foundation",
                gain: level, pan: pan, analogPatch: sound)

        case .fm:
            var sound = fmSeed(intent)
            if let brightness = target(.brightness, from: intent) {
                sound.set(0.07 + brightness * 0.75, for: .op2Level)
                sound.set(brightness * 0.6, for: .velocityBrightness)
            }
            if let metal = target(.metallicCharacter, from: intent) {
                sound.set(1 + metal * 7, for: .op2Ratio)
                sound.set(0.12 + metal * 0.55, for: .op3Level)
            }
            if let attack = target(.attackTime, from: intent) {
                sound.set(expRange(0.002, 6, attack), for: .op1Attack)
                sound.set(expRange(0.002, 6, attack), for: .op2Attack)
            }
            if let release = target(.releaseTime, from: intent) {
                sound.set(expRange(0.04, 10, release), for: .op1Release)
                sound.set(expRange(0.04, 10, release), for: .op2Release)
            }
            if let warmth = target(.warmth, from: intent) {
                sound.set(0.08 + (1 - warmth) * 0.4, for: .feedback)
            }
            if let aggression = target(.aggression, from: intent) {
                sound.set(0.12 + aggression * 0.68, for: .feedback)
            }
            if let low = target(.lowEnd, from: intent) {
                sound.set(low > 0.65 ? 0.5 : 1, for: .op1Ratio)
            }
            return StudioSynthLayer(
                id: id, engine: .fm, name: "FM Harmonics",
                gain: level, pan: pan, fmPatch: sound)

        case .wavetable:
            var sound = wavetableSeed(intent)
            if let brightness = target(.brightness, from: intent) {
                sound.set(0.25 + brightness * 4.5, for: .osc1Position)
            }
            if let metal = target(.metallicCharacter, from: intent) {
                sound.set(1 + 3.7 * metal, for: .osc2Position)
            }
            if let warmth = target(.warmth, from: intent) {
                sound.set(0.18 + 0.5 * warmth, for: .osc1Level)
            }
            if let attack = target(.attackTime, from: intent) {
                sound.set(expRange(0.002, 8, attack), for: .attack)
            }
            if let release = target(.releaseTime, from: intent) {
                sound.set(expRange(0.03, 12, release), for: .release)
            }
            if let movement = target(.movement, from: intent) {
                sound.set(0.72 * movement, for: .lfoDepth)
                sound.set(0.12 + 1.2 * movement, for: .lfoRate)
            }
            if let low = target(.lowEnd, from: intent) {
                sound.set(low > 0.65 ? -12 : 0, for: .osc2Detune)
            }
            if let complexity = target(.harmonicComplexity, from: intent) {
                sound.set(0.05 + 0.6 * complexity, for: .osc2Level)
            }
            return StudioSynthLayer(
                id: id, engine: .wavetable, name: "Wavetable Motion",
                gain: level, pan: pan, wavetablePatch: sound)

        case .additive:
            var sound = additiveSeed(intent)
            if let brightness = target(.brightness, from: intent) {
                sound.set(-1.3 + brightness * 2.6, for: .spectralTilt)
            }
            if let warmth = target(.warmth, from: intent) {
                sound.set(0.7 - warmth * 1.1, for: .spectralEvolution)
            }
            if let metal = target(.metallicCharacter, from: intent) {
                sound.set(-0.5 + 1.8 * metal, for: .spectralTilt)
            }
            if let complexity = target(.harmonicComplexity, from: intent) {
                for index in 1..<12 {
                    if let parameter = StudioAdditiveParameter.partial(index) {
                        let original = sound.value(for: parameter)
                        sound.set(min(1, original * (0.3 + 1.5 * complexity)),
                                  for: parameter)
                    }
                }
            }
            if let attack = target(.attackTime, from: intent) {
                sound.set(expRange(0.002, 8, attack), for: .attack)
            }
            if let release = target(.releaseTime, from: intent) {
                sound.set(expRange(0.03, 12, release), for: .release)
            }
            if let movement = target(.movement, from: intent) {
                sound.set(0.7 * movement, for: .motionDepth)
                sound.set(0.08 + 1.2 * movement, for: .motionRate)
            }
            if let low = target(.lowEnd, from: intent) {
                sound.set(0.6 - 1.5 * low, for: .spectralTilt)
            }
            if let spacious = target(.spaciousness, from: intent) {
                sound.set(0.2 + 0.75 * spacious, for: .motionSpread)
            }
            return StudioSynthLayer(
                id: id, engine: .additive, name: "Additive Spectrum",
                gain: level, pan: pan, additivePatch: sound)

        case .granular:
            var sound = granularSeed(intent)
            // All generation uses built-in procedural sources; imported audio
            // is never silently required to play a generated instrument.
            sound.importedAudioPath = nil
            if intent.excludedFamilies.contains(.bells) && sound.source == .bells {
                sound.source = .cloud
            }
            if intent.excludedFamilies.contains(.noise) && sound.source == .noise {
                sound.source = .cloud
            }
            if let warmth = target(.warmth, from: intent) {
                sound.set(0.04 + 0.4 * warmth, for: .grainSize)
            }
            if let brightness = target(.brightness, from: intent) {
                sound.set(0.28 - 0.2 * brightness, for: .grainSize)
            }
            if let attack = target(.attackTime, from: intent) {
                sound.set(expRange(0.002, 6, attack), for: .attack)
            }
            if let release = target(.releaseTime, from: intent) {
                sound.set(expRange(0.03, 10, release), for: .release)
            }
            if let movement = target(.movement, from: intent) {
                sound.set(-0.16 + 0.36 * movement, for: .scanSpeed)
                sound.set(0.08 + 0.42 * movement, for: .positionJitter)
            }
            if let noise = target(.noise, from: intent),
               noise > 0.65, !intent.excludedFamilies.contains(.noise) {
                sound.source = .noise
                sound.set(0.12 + 0.4 * noise, for: .pitchJitter)
            }
            if let low = target(.lowEnd, from: intent) {
                sound.set(low > 0.65 ? -12 : 0, for: .pitch)
            }
            if let spacious = target(.spaciousness, from: intent) {
                sound.set(0.15 + 0.85 * spacious, for: .panSpread)
            }
            if let aggression = target(.aggression, from: intent) {
                sound.set(0.2 + 6 * aggression, for: .pitchJitter)
            }
            return StudioSynthLayer(
                id: id, engine: .granular, name: "Granular Cloud",
                gain: level, pan: pan, granularPatch: sound)

        case .physical:
            var sound = physicalSeed(intent)
            if let brightness = target(.brightness, from: intent) {
                sound.set(brightness, for: .brightness)
            }
            if let warmth = target(.warmth, from: intent) {
                sound.set(0.1 + 0.8 * warmth, for: .bodyMix)
            }
            if let attack = target(.attackTime, from: intent) {
                // No general ADSR exists: soften/strengthen the excitation.
                sound.set(0.85 - 0.7 * attack, for: .pickHardness)
                sound.set(0.82 - 0.45 * attack, for: .bowPressure)
            }
            if let release = target(.releaseTime, from: intent) {
                sound.set(expRange(0.03, 4, release), for: .release)
            }
            if let metal = target(.metallicCharacter, from: intent) {
                sound.set(0.24 + 0.76 * metal, for: .percussionInharmonicity)
                sound.set(0.13 + metal * 0.8, for: .stiffness)
            }
            if let noise = target(.noise, from: intent) {
                sound.set(0.68 * noise, for: .airNoise)
                sound.set(0.47 * noise, for: .bowNoise)
            }
            if let low = target(.lowEnd, from: intent) {
                sound.set(0.15 + 0.8 * low, for: .bodySize)
            }
            if let aggression = target(.aggression, from: intent) {
                sound.set(0.18 + 0.8 * aggression, for: .pickHardness)
                sound.set(0.2 + 0.7 * aggression, for: .percussionHardness)
            }
            return StudioSynthLayer(
                id: id, engine: .physical, name: "Acoustic Resonance",
                gain: level, pan: pan, physicalPatch: sound)
        }
    }

    // MARK: Seed selection

    private static func analogSeed(_ intent: StudioSoundDescriptionIntent) -> StudioAnalogPatch {
        let name: String
        switch intent.role {
        case .bass: name = "Sub Foundation"
        case .lead: name = "Copper Sky"
        case .keys: name = "Soft Circuit"
        case .pluck, .percussion: name = "Clockwork"
        case .texture: name = "Signal Fog"
        default: name = "Midnight Strings"
        }
        return StudioAnalogFactoryLibrary.presets.first(where: { $0.name == name })?.patch
            ?? StudioAnalogPatch()
    }

    private static func fmSeed(_ intent: StudioSoundDescriptionIntent) -> StudioFMPatch {
        let name: String
        if intent.families.contains(.bells) { name = "Orbit Bell" }
        else if intent.families.contains(.voice) { name = "Halo Choir" }
        else {
            switch intent.role {
            case .bass: name = "Reactor Low"
            case .lead: name = "Arc Light"
            case .keys, .pluck: name = "Satin Electric"
            case .percussion: name = "Circuit Clack"
            case .texture: name = "Glass Storm"
            default: name = "Halo Choir"
            }
        }
        return StudioFMFactoryLibrary.presets.first(where: { $0.name == name })?.patch
            ?? StudioFMPatch()
    }

    private static func wavetableSeed(
        _ intent: StudioSoundDescriptionIntent
    ) -> StudioWavetablePatch {
        let name: String
        switch intent.role {
        case .bass: name = "Carbon Pulse"
        case .lead: name = "Solar Flare"
        case .keys, .pluck: name = "Velvet Phase"
        case .texture: name = "Starfield Dust"
        default: name = "Polar Silk"
        }
        return StudioWavetableFactoryLibrary.presets.first(where: { $0.name == name })?.patch
            ?? StudioWavetablePatch()
    }

    private static func additiveSeed(
        _ intent: StudioSoundDescriptionIntent
    ) -> StudioAdditivePatch {
        let name: String
        if intent.families.contains(.strings) { name = "Amber Ensemble" }
        else if intent.families.contains(.brass) { name = "Granite Brass" }
        else if intent.families.contains(.woodwinds) { name = "Breath Organ" }
        else if intent.families.contains(.bells) { name = "Celestial Celesta" }
        else {
            switch intent.role {
            case .bass: name = "Sub Harmonic"
            case .keys, .pluck: name = "Soft Tine Choir"
            case .texture: name = "Solar Filaments"
            default: name = "Evolving Hollow"
            }
        }
        return StudioAdditiveFactoryLibrary.presets.first(where: { $0.name == name })?.patch
            ?? StudioAdditivePatch()
    }

    private static func granularSeed(
        _ intent: StudioSoundDescriptionIntent
    ) -> StudioGranularPatch {
        let name: String
        if intent.families.contains(.bells) { name = "Crystal Rain" }
        else if intent.families.contains(.strings) { name = "Aurora Veil" }
        else if intent.families.contains(.noise) { name = "Black Sand" }
        else {
            switch intent.role {
            case .bass: name = "Deep Engine"
            case .lead: name = "Frost Signal"
            case .keys, .pluck: name = "Copper Fragments"
            case .texture: name = "Reverse Halo"
            default: name = "Vapor Cathedral"
            }
        }
        return StudioGranularFactoryLibrary.presets.first(where: { $0.name == name })?.patch
            ?? StudioGranularPatch()
    }

    private static func physicalSeed(
        _ intent: StudioSoundDescriptionIntent
    ) -> StudioPhysicalPatch {
        let name: String
        if intent.families.contains(.brass) { name = "Mellow Horn" }
        else if intent.families.contains(.woodwinds) { name = "Dark Clarinet" }
        else if intent.families.contains(.bells) { name = "Silver Bell" }
        else if intent.families.contains(.strings) {
            name = intent.role == .pad ? "Soft Bow" : "Fingerstyle Cedar"
        } else {
            switch intent.role {
            case .keys: name = "Felt Upright"
            case .percussion: name = "Soft Marimba"
            case .pad: name = "Soft Bow"
            default: name = "Warm Nylon"
            }
        }
        return StudioPhysicalFactoryLibrary.presets.first(where: { $0.name == name })?.patch
            ?? StudioPhysicalPatch()
    }

    private static func motionDestination(for engine: StudioSynthEngine)
        -> StudioSynthModDestination {
        switch engine {
        case .analog: return .analog(.filterCutoff)
        case .fm: return .fm(.feedback)
        case .wavetable: return .wavetable(.osc1Position)
        case .additive: return .additive(.spectralTilt)
        case .granular: return .granular(.scanSpeed)
        case .physical: return .physical(.brightness)
        }
    }

    // MARK: Safe parameter helpers

    private static func target(
        _ quality: StudioSoundQuality, from intent: StudioSoundDescriptionIntent
    ) -> Float? {
        guard let instruction = intent.instruction(for: quality) else { return nil }
        let value: Float
        switch instruction.action {
        case .set: value = instruction.amount
        case .increase: value = 0.5 + instruction.amount
        case .decrease: value = 0.5 - instruction.amount
        }
        return min(1, max(0, value))
    }

    private static func expRange(
        _ lower: Float, _ upper: Float, _ normalized: Float
    ) -> Float {
        Float(Double(lower) * pow(Double(upper / lower), Double(normalized)))
    }

    /// Stable layer/route IDs make re-running the same interpretation
    /// reproducible. They identify sound-local targets, never user identity.
    private static func stableUUID(_ seed: String, index: Int) -> UUID {
        func hash(_ salt: UInt64) -> UInt64 {
            var value: UInt64 = 14_695_981_039_346_656_037 ^ salt
            for byte in seed.utf8 {
                value ^= UInt64(byte)
                value = value &* 1_099_511_628_211
            }
            return value
        }
        let hi = String(format: "%016llx", hash(UInt64(index + 1)))
        let lo = String(format: "%016llx", hash(UInt64(index + 10_001)))
        let joined = hi + lo
        let uuid = "\(joined.prefix(8))-\(joined.dropFirst(8).prefix(4))-\(joined.dropFirst(12).prefix(4))-\(joined.dropFirst(16).prefix(4))-\(joined.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuid)! // 32 lowercase ASCII hex digits
    }
}
