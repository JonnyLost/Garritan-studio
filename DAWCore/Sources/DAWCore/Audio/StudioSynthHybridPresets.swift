import Foundation

/// Original multi-engine combinations. Each layer uses Studio's own native
/// DSP, and preset parameters remain editable and project-owned.
public struct StudioSynthHybridPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let summary: String
    public let patch: StudioSynthPatch

    public init(name: String, family: String, summary: String,
                patch: StudioSynthPatch) {
        id = "\(family.lowercased())-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        self.name = name
        self.family = family
        self.summary = summary
        self.patch = patch
    }
}

public enum StudioSynthHybridFactoryLibrary {
    private static func analog(_ name: String, gain: Float = 0.32,
                               pan: Float = -0.12, cutoff: Float = 1800,
                               attack: Float = 0.08) -> StudioSynthLayer {
        var patch = StudioAnalogPatch()
        patch.set(cutoff, for: .filterCutoff)
        patch.set(attack, for: .amplitudeAttack)
        return StudioSynthLayer(engine: .analog, name: name, gain: gain,
                                pan: pan, analogPatch: patch)
    }

    private static func fm(_ name: String, gain: Float = 0.34,
                           pan: Float = 0.06, feedback: Float = 0.22)
        -> StudioSynthLayer {
        var patch = StudioFMPatch()
        patch.set(feedback, for: .feedback)
        return StudioSynthLayer(engine: .fm, name: name, gain: gain,
                                pan: pan, fmPatch: patch)
    }

    private static func wavetable(_ name: String, gain: Float = 0.31,
                                  pan: Float = 0.12,
                                  position: Float = 1.7) -> StudioSynthLayer {
        var patch = StudioWavetablePatch()
        patch.set(position, for: .osc1Position)
        patch.set(0.23, for: .osc2Level)
        return StudioSynthLayer(engine: .wavetable, name: name, gain: gain,
                                pan: pan, wavetablePatch: patch)
    }

    private static func additive(_ name: String, sound: String,
                                 gain: Float = 0.38,
                                 pan: Float = -0.07) -> StudioSynthLayer {
        let preset = StudioAdditiveFactoryLibrary.presets.first {
            $0.name == sound
        }?.patch ?? StudioAdditivePatch()
        return StudioSynthLayer(engine: .additive, name: name, gain: gain,
                                pan: pan, additivePatch: preset)
    }

    private static func make(_ name: String, _ family: String,
                             _ summary: String, layers: [StudioSynthLayer],
                             motion: Bool = false) -> StudioSynthHybridPreset {
        var modulation: StudioSynthModulationSettings?
        if motion, let moving = layers.first(where: {
            $0.engine == .additive || $0.engine == .wavetable
        }) {
            let target: StudioSynthModDestination =
                moving.engine == .additive
                ? .additive(.spectralTilt)
                : .wavetable(.osc1Position)
            modulation = StudioSynthModulationSettings(
                routes: [StudioSynthModRoute(source: .lfo1,
                                             layerID: moving.id,
                                             destination: target,
                                             depth: 0.12)])
        }
        return StudioSynthHybridPreset(
            name: name, family: family, summary: summary,
            patch: StudioSynthPatch(layers: layers, modulation: modulation))
    }

    public static let presets: [StudioSynthHybridPreset] = [
        make("Orchestral Vapor", "Cinematic",
             "Slow native Analog and evolving Additive foundation.",
             layers: [analog("Warm Body", gain: 0.33, cutoff: 1050, attack: 0.24),
                      additive("High String Air", sound: "Warm String Bed",
                               gain: 0.42, pan: 0.09)], motion: true),
        make("Glass Horizon", "Cinematic",
             "Spectral upper harmonics and a swelling Wavetable bed.",
             layers: [additive("Glass Overtones", sound: "Glass Bloom",
                               gain: 0.38),
                      wavetable("Floating Wave", gain: 0.34,
                                position: 3.8, pan: 0.16)], motion: true),
        make("Dark Choir", "Cinematic",
             "Hollow harmonic choir with a smooth FM edge.",
             layers: [additive("Choir Formants", sound: "Deep Choir Cloud",
                               gain: 0.42),
                      fm("FM Breath", gain: 0.24, feedback: 0.1)], motion: true),
        make("Spectral Morning", "Pads",
             "Airy upper voices under a slowly moving Analog foundation.",
             layers: [analog("Soft Analog", cutoff: 1400, attack: 0.4),
                      additive("Slow Spectrum", sound: "Spectral Aurora",
                               gain: 0.32, pan: 0.12)], motion: true),
        make("Prism Drift", "Pads",
             "Wavetable motion with a delicate additive glass layer.",
             layers: [wavetable("Moving Wave", position: 4.1, gain: 0.34),
                      additive("Prism Harmonics", sound: "Digital Prism",
                               gain: 0.27)], motion: true),
        make("Tine and Bell", "Keys",
             "Focused FM transient with original harmonic chime tail.",
             layers: [fm("Tine Body", gain: 0.43, feedback: 0.18),
                      additive("Bell Tail", sound: "Bell Keys",
                               gain: 0.34, pan: 0.13)]),
        make("Pure Spectrum Keys", "Keys",
             "Simple additive tone layered with a rounded FM note.",
             layers: [additive("Fundamental", sound: "Pure Foundation",
                               gain: 0.4),
                      fm("FM Color", gain: 0.27, feedback: 0.12)]),
        make("Bass Cathedral", "Bass",
             "Deep harmonic bass reinforced by a smooth Analog oscillator.",
             layers: [additive("Octave Low End", sound: "Octave Pillar",
                               gain: 0.38),
                      analog("Analog Sub", gain: 0.3, cutoff: 480,
                             attack: 0.006, pan: 0)]),
        make("Timbre Atlas", "Textures",
             "Three-engine evolving texture, tuned for moderate layer levels.",
             layers: [additive("Harmonic Motion", sound: "Evolving Hollow",
                               gain: 0.31),
                      wavetable("Wavetable Accent", gain: 0.26,
                                position: 2.8),
                      fm("Digital Breath", gain: 0.22, feedback: 0.13)],
             motion: true),
        make("Fourfold Spectrum", "Textures",
             "All four native synth engines, individually adjustable.",
             layers: [analog("Analog Root", gain: 0.23, cutoff: 1400),
                      fm("FM Edge", gain: 0.19, feedback: 0.11),
                      wavetable("Wave Motion", gain: 0.2,
                                position: 1.3),
                      additive("Spectral Air", sound: "Silver Flute",
                               gain: 0.22)], motion: true)
    ]
}
