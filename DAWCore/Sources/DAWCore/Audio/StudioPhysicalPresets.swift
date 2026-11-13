import Foundation

/// Factory configurations for original, algorithmic physical-modeling voices.
/// Names describe the synthesis intent, not a claim of sampled realism.
public struct StudioPhysicalPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let summary: String
    public let patch: StudioPhysicalPatch

    public init(name: String, family: String, summary: String,
                patch: StudioPhysicalPatch) {
        id = "\(family.lowercased())-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        self.name = name
        self.family = family
        self.summary = summary
        self.patch = patch
    }
}

public enum StudioPhysicalFactoryLibrary {
    private static func make(
        _ name: String, family: String, description: String,
        model: StudioPhysicalModel, controls: [(StudioPhysicalParameter, Float)]
    ) -> StudioPhysicalPreset {
        var patch = StudioPhysicalPatch()
        patch.set(Float(model.rawValue), for: .model)
        for (parameter, value) in controls { patch.set(value, for: parameter) }
        return StudioPhysicalPreset(name: name, family: family,
                                    summary: description, patch: patch)
    }

    public static let presets: [StudioPhysicalPreset] = [
        make("Warm Nylon", family: "Strings", description: "Rounded finger-plucked string.",
             model: .plucked, controls: [
                (.brightness, 0.28), (.damping, 0.67),
                (.pickHardness, 0.12), (.bodyMix, 0.36), (.release, 0.35)]),
        make("Bright Steel", family: "Strings", description: "Hard-picked resonant string.",
             model: .plucked, controls: [
                (.brightness, 0.84), (.damping, 0.85),
                (.pickHardness, 0.88), (.stiffness, 0.3), (.release, 0.7)]),
        make("Felt Hammer", family: "Keys", description: "Soft struck-string attack.",
             model: .struck, controls: [
                (.brightness, 0.34), (.pickHardness, 0.23),
                (.bodyMix, 0.55), (.release, 0.42)]),
        make("Bow Resonance", family: "Strings", description: "Continuous bowed-string prototype.",
             model: .bowed, controls: [
                (.bowPressure, 0.68), (.bowSpeed, 0.72),
                (.bowNoise, 0.08), (.bodyMix, 0.4), (.release, 0.55)]),
        make("Reed Chamber", family: "Winds", description: "Breath-driven reed prototype.",
             model: .reed, controls: [
                (.breath, 0.82), (.reedStiffness, 0.65),
                (.bore, 0.35), (.airNoise, 0.08), (.release, 0.25)]),
        make("Open Brass", family: "Brass", description: "Lip-valve brass prototype.",
             model: .brass, controls: [
                (.breath, 0.95), (.reedStiffness, 0.5),
                (.bore, 0.76), (.airNoise, 0.06), (.release, 0.32)]),
        make("Soft Marimba", family: "Percussion", description: "Soft-struck tuned wooden-bar modes.",
             model: .mallet, controls: [
                (.percussionHardness, 0.18), (.percussionDecay, 0.55),
                (.percussionInharmonicity, 0.92), (.percussionAttackNoise, 0.06)]),
        make("Bright Xylophone", family: "Percussion", description: "Sharp wooden-bar transient.",
             model: .mallet, controls: [
                (.percussionHardness, 0.92), (.percussionDecay, 0.18),
                (.percussionInharmonicity, 0.95), (.percussionAttackNoise, 0.36)]),
        make("Silver Bell", family: "Percussion", description: "Long metallic modal decay.",
             model: .bell, controls: [
                (.percussionHardness, 0.83), (.percussionDecay, 0.93),
                (.percussionInharmonicity, 1), (.percussionAttackNoise, 0.08)]),
        make("Bronze Chime", family: "Percussion", description: "Dense inharmonic metal ringing.",
             model: .bell, controls: [
                (.percussionHardness, 0.54), (.percussionDecay, 0.76),
                (.percussionInharmonicity, 0.73), (.position, 0.8)]),
        make("Kettle Skin", family: "Percussion", description: "Pitch-following membrane resonance.",
             model: .membrane, controls: [
                (.percussionHardness, 0.42), (.percussionDecay, 0.72),
                (.percussionInharmonicity, 1), (.percussionAttackNoise, 0.34)]),
        make("Short Tom", family: "Percussion", description: "Short damped membrane impulse.",
             model: .membrane, controls: [
                (.percussionHardness, 0.74), (.percussionDecay, 0.13),
                (.percussionInharmonicity, 0.9), (.percussionAttackNoise, 0.55)])
    ]
}
