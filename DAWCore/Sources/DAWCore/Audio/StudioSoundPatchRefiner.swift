import Foundation

// MARK: - Sound Designer Milestone 3: non-destructive patch refinement

/// One concrete, user-reviewable edit. Values are native Synth parameter
/// values (not ambiguous language-model scores).
public struct StudioSoundRefinementChange: Equatable, Sendable {
    public let layerID: UUID
    public let layerName: String
    public let control: String
    public let destination: StudioSynthModDestination?
    public let before: Float
    public let after: Float
}

public struct StudioSoundRefinementResult: Equatable, Sendable {
    public let prompt: String
    public let before: StudioSynthPatch
    public let patch: StudioSynthPatch
    public let changes: [StudioSoundRefinementChange]
    public let limitations: [String]

    public var summary: [String] {
        changes.map {
            "\($0.layerName): \($0.control) \(String(format: "%.3f", $0.before)) → \(String(format: "%.3f", $0.after))"
        }
    }
}

public enum StudioSoundPatchRefinementError: Error, LocalizedError, Equatable {
    case invalidExistingPatch
    case requiresRefinementIntent
    case noQualityInstruction
    case noMatchingLayer
    case noEffectiveChange
    case invalidRefinedPatch

    public var errorDescription: String? {
        switch self {
        case .invalidExistingPatch: return "The original Synth patch is not valid."
        case .requiresRefinementIntent: return "Use refinement mode to edit an existing Synth sound."
        case .noQualityInstruction: return "Describe how to change the sound (for example, 'darker' or 'slower attack')."
        case .noMatchingLayer: return "There is no enabled Synth layer matching that engine."
        case .noEffectiveChange: return "That request cannot change the available Synth controls."
        case .invalidRefinedPatch: return "Refinement was rejected; the previous sound was preserved."
        }
    }
}

/// Pure, deterministic patch-to-patch editing. This never touches the audio
/// graph, project storage, sampler source paths, MIDI Learn or existing routes.
/// All edits use the native parameter validators and normalized UI curves.
public enum StudioSoundPatchRefiner {
    private struct Control {
        let destination: StudioSynthModDestination
        let inverted: Bool
        init(_ destination: StudioSynthModDestination, inverted: Bool = false) {
            self.destination = destination
            self.inverted = inverted
        }
    }

    public static func refine(
        _ description: String, patch: StudioSynthPatch
    ) throws -> StudioSoundRefinementResult {
        try refine(
            from: StudioSoundDescriptionInterpreter.interpret(description, mode: .refine),
            patch: patch)
    }

    public static func refine(
        from intent: StudioSoundDescriptionIntent,
        patch original: StudioSynthPatch
    ) throws -> StudioSoundRefinementResult {
        guard original.validate() else {
            throw StudioSoundPatchRefinementError.invalidExistingPatch
        }
        guard intent.mode == .refine else {
            throw StudioSoundPatchRefinementError.requiresRefinementIntent
        }
        guard !intent.instructions.isEmpty else {
            throw StudioSoundPatchRefinementError.noQualityInstruction
        }
        let eligible = original.layers.indices.filter { index in
            let layer = original.layers[index]
            return layer.enabled &&
                (intent.engineHints.isEmpty || intent.engineHints.contains(layer.engine)) &&
                !intent.excludedEngines.contains(layer.engine)
        }
        guard !eligible.isEmpty else {
            throw StudioSoundPatchRefinementError.noMatchingLayer
        }

        var refined = original
        var changes: [StudioSoundRefinementChange] = []
        var limitations: [String] = []
        let stereoLayers = original.layers.filter(\.enabled).count > 1

        for index in eligible {
            for instruction in intent.instructions {
                let controls = controls(for: instruction.quality, layer: refined.layers[index])
                for control in controls {
                    let old = read(control.destination, from: refined.layers[index])
                    let position = control.destination.position(for: old)
                    let orientation: Double = control.inverted ? -1 : 1
                    let next: Double
                    switch instruction.action {
                    case .set:
                        let desired = Double(instruction.amount)
                        next = control.inverted ? 1 - desired : desired
                    case .increase:
                        next = position + Double(instruction.amount) * orientation
                    case .decrease:
                        next = position - Double(instruction.amount) * orientation
                    }
                    let bounded = min(1, max(0, next))
                    let value = control.destination.value(at: bounded)
                    guard control.destination.valid(value), abs(value - old) > 0.000001 else {
                        continue
                    }
                    write(value, for: control.destination, to: &refined.layers[index])
                    changes.append(StudioSoundRefinementChange(
                        layerID: refined.layers[index].id,
                        layerName: refined.layers[index].name,
                        control: control.destination.title,
                        destination: control.destination,
                        before: old, after: value))
                }

                // Stereo width is a layer property, not an invented hall send.
                // Preserve original left/right orientation and all gain levels.
                if instruction.quality == .spaciousness && stereoLayers {
                    let old = refined.layers[index].pan
                    let sign: Float = old == 0 ? (index.isMultiple(of: 2) ? -1 : 1)
                                               : (old < 0 ? -1 : 1)
                    let magnitude = abs(old)
                    let next: Float
                    switch instruction.action {
                    case .set: next = min(0.35, instruction.amount * 0.35)
                    case .increase: next = min(0.35, magnitude + instruction.amount * 0.24)
                    case .decrease: next = max(0, magnitude - instruction.amount * 0.24)
                    }
                    let value = sign * next
                    if abs(value - old) > 0.000001 {
                        refined.layers[index].pan = value
                        changes.append(StudioSoundRefinementChange(
                            layerID: refined.layers[index].id,
                            layerName: refined.layers[index].name,
                            control: "Layer Pan", destination: nil,
                            before: old, after: value))
                    }
                }
            }
        }

        if intent.instruction(for: .spaciousness) != nil {
            limitations.append("Width uses native stereo controls; no reverb or mixer send is modified.")
        }
        if intent.instruction(for: .attackTime) != nil &&
            eligible.contains(where: { original.layers[$0].engine == .physical }) {
            limitations.append("Physical Modeling has no general attack envelope; excitation hardness is adjusted instead.")
        }
        for instruction in intent.instructions {
            if !changes.contains(where: { change in
                // No parameter was changed for this quality on any eligible
                // layer. Report it instead of claiming sound matching.
                eligible.contains(where: { index in
                    let layer = original.layers[index]
                    return layer.id == change.layerID &&
                        (controls(for: instruction.quality, layer: layer)
                            .contains(where: { $0.destination == change.destination }) ||
                         (instruction.quality == .spaciousness && change.control == "Layer Pan"))
                })
            }) {
                limitations.append("No adjustable native control was changed for \(instruction.quality.rawValue).")
            }
        }

        guard !changes.isEmpty else {
            throw StudioSoundPatchRefinementError.noEffectiveChange
        }
        guard refined.validate() else {
            throw StudioSoundPatchRefinementError.invalidRefinedPatch
        }
        return StudioSoundRefinementResult(
            prompt: intent.originalText, before: original,
            patch: refined, changes: changes, limitations: limitations)
    }

    private static func controls(
        for quality: StudioSoundQuality, layer: StudioSynthLayer
    ) -> [Control] {
        let engine = layer.engine
        switch quality {
        case .brightness:
            switch engine {
            case .analog: return [Control(.analog(.filterCutoff))]
            case .fm: return [Control(.fm(.op2Level)), Control(.fm(.velocityBrightness))]
            case .wavetable: return [Control(.wavetable(.osc1Position))]
            case .additive: return [Control(.additive(.spectralTilt))]
            case .granular: return [Control(.granular(.grainSize), inverted: true)]
            case .physical: return [Control(.physical(.brightness))]
            }
        case .warmth:
            switch engine {
            case .analog: return [Control(.analog(.filterCutoff), inverted: true)]
            case .fm: return [Control(.fm(.feedback), inverted: true)]
            case .wavetable: return [Control(.wavetable(.osc1Level))]
            case .additive: return [Control(.additive(.spectralEvolution), inverted: true)]
            case .granular: return [Control(.granular(.grainSize))]
            case .physical: return [Control(.physical(.bodyMix))]
            }
        case .attackTime:
            switch engine {
            case .analog: return [Control(.analog(.amplitudeAttack))]
            case .fm: return [Control(.fm(.op1Attack)), Control(.fm(.op2Attack))]
            case .wavetable: return [Control(.wavetable(.attack))]
            case .additive: return [Control(.additive(.attack))]
            case .granular: return [Control(.granular(.attack))]
            case .physical:
                switch layer.physicalPatch?.model ?? .plucked {
                case .plucked, .struck:
                    return [Control(.physical(.pickHardness), inverted: true)]
                case .bowed:
                    return [Control(.physical(.bowPressure), inverted: true)]
                case .reed, .brass:
                    return [Control(.physical(.breath), inverted: true)]
                case .mallet, .bell, .membrane:
                    return [Control(.physical(.percussionHardness), inverted: true)]
                }
            }
        case .releaseTime:
            switch engine {
            case .analog: return [Control(.analog(.amplitudeRelease))]
            case .fm: return [Control(.fm(.op1Release)), Control(.fm(.op2Release))]
            case .wavetable: return [Control(.wavetable(.release))]
            case .additive: return [Control(.additive(.release))]
            case .granular: return [Control(.granular(.release))]
            case .physical: return [Control(.physical(.release))]
            }
        case .movement:
            switch engine {
            case .analog: return [Control(.analog(.lfoDepth))]
            case .fm: return [Control(.fm(.modDepth))]
            case .wavetable: return [Control(.wavetable(.lfoDepth))]
            case .additive: return [Control(.additive(.motionDepth))]
            case .granular: return [Control(.granular(.positionJitter))]
            case .physical: return [Control(.physical(.bowSpeed))]
            }
        case .metallicCharacter:
            switch engine {
            case .analog: return [Control(.analog(.resonance))]
            case .fm: return [Control(.fm(.op2Ratio))]
            case .wavetable: return [Control(.wavetable(.osc2Position))]
            case .additive: return [Control(.additive(.spectralTilt))]
            case .granular: return [Control(.granular(.pitchJitter))]
            case .physical: return [Control(.physical(.stiffness))]
            }
        case .noise:
            switch engine {
            case .analog: return [Control(.analog(.noiseLevel))]
            case .physical: return [Control(.physical(.airNoise)), Control(.physical(.bowNoise))]
            default: return []
            }
        case .lowEnd:
            switch engine {
            case .analog: return [Control(.analog(.oscillator2Level))]
            case .fm: return []
            case .wavetable: return [Control(.wavetable(.osc2Level))]
            case .additive: return [Control(.additive(.spectralTilt), inverted: true)]
            case .granular: return [Control(.granular(.grainSize))]
            case .physical: return [Control(.physical(.bodySize))]
            }
        case .spaciousness:
            switch engine {
            case .additive: return [Control(.additive(.motionSpread))]
            case .granular: return [Control(.granular(.panSpread))]
            default: return []
            }
        case .aggression:
            switch engine {
            case .analog: return [Control(.analog(.filterEnvelopeDepth))]
            case .fm: return [Control(.fm(.feedback))]
            case .wavetable: return [Control(.wavetable(.osc2Level))]
            case .additive: return [Control(.additive(.spectralTilt))]
            case .granular: return [Control(.granular(.pitchJitter))]
            case .physical: return [Control(.physical(.pickHardness))]
            }
        case .harmonicComplexity:
            switch engine {
            case .analog: return [Control(.analog(.oscillator2Level))]
            case .fm: return [Control(.fm(.op3Level))]
            case .wavetable: return [Control(.wavetable(.osc2Level))]
            case .additive: return [Control(.additive(.partial3))]
            case .granular: return [Control(.granular(.pitchJitter))]
            case .physical: return [Control(.physical(.stiffness))]
            }
        }
    }

    private static func read(
        _ destination: StudioSynthModDestination, from layer: StudioSynthLayer
    ) -> Float {
        switch destination {
        case .analog(let p):
            return (layer.analogPatch ?? StudioAnalogPatch()).value(for: p)
        case .fm(let p):
            return (layer.fmPatch ?? StudioFMPatch()).value(for: p)
        case .wavetable(let p):
            return (layer.wavetablePatch ?? StudioWavetablePatch()).value(for: p)
        case .additive(let p):
            return (layer.additivePatch ?? StudioAdditivePatch()).value(for: p)
        case .granular(let p):
            return (layer.granularPatch ?? StudioGranularPatch()).value(for: p)
        case .physical(let p):
            return (layer.physicalPatch ?? StudioPhysicalPatch()).value(for: p)
        }
    }

    private static func write(
        _ value: Float, for destination: StudioSynthModDestination,
        to layer: inout StudioSynthLayer
    ) {
        switch destination {
        case .analog(let p):
            var sound = layer.analogPatch ?? StudioAnalogPatch()
            sound.set(value, for: p)
            layer.analogPatch = sound
        case .fm(let p):
            var sound = layer.fmPatch ?? StudioFMPatch()
            sound.set(value, for: p)
            layer.fmPatch = sound
        case .wavetable(let p):
            var sound = layer.wavetablePatch ?? StudioWavetablePatch()
            sound.set(value, for: p)
            layer.wavetablePatch = sound
        case .additive(let p):
            var sound = layer.additivePatch ?? StudioAdditivePatch()
            sound.set(value, for: p)
            layer.additivePatch = sound
        case .granular(let p):
            var sound = layer.granularPatch ?? StudioGranularPatch()
            sound.set(value, for: p)
            layer.granularPatch = sound
        case .physical(let p):
            var sound = layer.physicalPatch ?? StudioPhysicalPatch()
            sound.set(value, for: p)
            layer.physicalPatch = sound
        }
    }
}

/// In-memory snapshot history for future preview/compare UI. Undo/redo returns
/// ordinary Synth patches; the caller decides when to audition or commit them
/// via ProjectViewModel.updateStudioSynthPatch (which already registers DAW undo).
public struct StudioSoundRefinementHistory: Sendable {
    public static let maximumSteps = 32
    private var snapshots: [StudioSynthPatch]
    public private(set) var steps: [StudioSoundRefinementResult] = []
    public private(set) var cursor: Int = 0

    public init(patch: StudioSynthPatch) throws {
        guard patch.validate() else {
            throw StudioSoundPatchRefinementError.invalidExistingPatch
        }
        snapshots = [patch]
    }

    public var currentPatch: StudioSynthPatch { snapshots[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < steps.count }

    @discardableResult
    public mutating func refine(_ description: String) throws
        -> StudioSoundRefinementResult {
        // Compute first: a failure must never truncate undo/redo history.
        let result = try StudioSoundPatchRefiner.refine(description, patch: currentPatch)
        steps = Array(steps.prefix(cursor))
        snapshots = Array(snapshots.prefix(cursor + 1))
        steps.append(result)
        snapshots.append(result.patch)
        if steps.count > Self.maximumSteps {
            steps.removeFirst()
            snapshots.removeFirst()
        }
        cursor = steps.count
        return result
    }

    @discardableResult
    public mutating func undo() -> StudioSynthPatch? {
        guard canUndo else { return nil }
        cursor -= 1
        return currentPatch
    }

    @discardableResult
    public mutating func redo() -> StudioSynthPatch? {
        guard canRedo else { return nil }
        cursor += 1
        return currentPatch
    }

    /// Cancel all uncommitted experiments and restore the initial snapshot.
    public mutating func reset(to patch: StudioSynthPatch) throws {
        guard patch.validate() else {
            throw StudioSoundPatchRefinementError.invalidExistingPatch
        }
        snapshots = [patch]
        steps = []
        cursor = 0
    }
}
