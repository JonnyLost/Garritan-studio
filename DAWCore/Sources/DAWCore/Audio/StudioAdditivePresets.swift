import Foundation

/// Mathematically synthesized Studio-owned sounds, no audio recordings or
/// externally licensed waveforms. Every sound is embedded in the project.
public struct StudioAdditivePreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let summary: String
    public let patch: StudioAdditivePatch

    public init(name: String, family: String, summary: String,
                patch: StudioAdditivePatch) {
        id = "\(family.lowercased())-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        self.name = name
        self.family = family
        self.summary = summary
        self.patch = patch
    }
}

public enum StudioAdditiveFactoryLibrary {
    private static func make(
        _ name: String, _ family: String, _ summary: String,
        harmonics: [Float], attack: Float = 0.008, decay: Float = 0.28,
        sustain: Float = 0.72, release: Float = 0.3,
        tilt: Float = 0, evolve: Float = 0.45,
        evolveTime: Float = 1.8, gain: Float = 0.65
    ) -> StudioAdditivePreset {
        var patch = StudioAdditivePatch()
        for i in 0..<16 {
            patch.set(i<harmonics.count ? harmonics[i] : 0,
                      for: StudioAdditiveParameter.partial(i)!)
        }
        for (p,value): (StudioAdditiveParameter, Float) in [
            (.attack,attack),(.decay,decay),(.sustain,sustain),
            (.release,release),(.spectralTilt,tilt),
            (.spectralEvolution,evolve),(.evolutionTime,evolveTime),
            (.outputGain,gain)
        ] {
            patch.set(value,for:p)
        }
        return StudioAdditivePreset(name:name,family:family,
                                    summary:summary,patch:patch)
    }

    public static let presets: [StudioAdditivePreset] = [
        make("Pure Foundation","Keys","Sine-rich fundamental for clear melodic lines.",
             harmonics:[0.95,0.04,0.02],evolve:0,gain:0.74),
        make("Bell Keys","Keys","Sparse upper harmonics with a decaying chime.",
             harmonics:[0.58,0.05,0.45,0,0.28,0,0.15,0,0.11],
             attack:0.002,decay:1.1,sustain:0.05,release:1.8,
             tilt:0.1,evolve:1.0,evolveTime:0.55),
        make("Tine Spark","Keys","Soft electric-key-like upper spectrum.",
             harmonics:[0.78,0.29,0.23,0.1,0.08,0.055,0.04],
             attack:0.002,decay:0.5,sustain:0.3,release:0.6,
             evolve:0.9,evolveTime:0.3),
        make("Hollow Reed","Winds","Odd-biased airy harmonic reed.",
             harmonics:[0.65,0.03,0.52,0.02,0.23,0,0.11,0,0.06],
             attack:0.055,decay:0.25,sustain:0.86,release:0.23,
             tilt:-0.1,evolve:-0.25),
        make("Silver Flute","Winds","Mostly fundamental with gentle upper sparkle.",
             harmonics:[0.92,0.09,0.04,0.02,0.015],
             attack:0.07,decay:0.2,sustain:0.9,release:0.32,
             tilt:-0.6,evolve:0.6,evolveTime:1.1),
        make("Brass Outline","Winds","Broad, rising harmonic brass gesture.",
             harmonics:[0.62,0.35,0.28,0.19,0.15,0.12,0.09,0.06,0.05],
             attack:0.1,decay:0.32,sustain:0.88,release:0.26,
             tilt:0.05,evolve:-0.7,evolveTime:0.8),
        make("Warm String Bed","Pads","Slow, gentle harmonics for layered string textures.",
             harmonics:[0.72,0.29,0.17,0.11,0.08,0.06,0.04,0.03],
             attack:0.65,decay:0.75,sustain:0.82,release:2.4,
             tilt:-0.25,evolve:0.45,evolveTime:2.8),
        make("Glass Bloom","Pads","Upper harmonics appear and drift across a long chord.",
             harmonics:[0.6,0.08,0.3,0.05,0.27,0.08,0.2,0,0.13,0.04,0.09],
             attack:1.2,decay:1.8,sustain:0.75,release:3.4,
             tilt:-0.15,evolve:-1.1,evolveTime:3.6),
        make("Deep Choir Cloud","Pads","Vowel-like spectral bed built entirely from sines.",
             harmonics:[0.42,0.17,0.5,0.16,0.28,0.08,0.17,0.08,0.09,0.04],
             attack:0.8,decay:1.2,sustain:0.9,release:3.2,
             tilt:-0.35,evolve:0.65,evolveTime:2.0),
        make("Octave Pillar","Bass","Powerful fundamental and octave harmonics.",
             harmonics:[0.85,0.55,0.11,0.19,0.07,0.06],
             attack:0.006,decay:0.32,sustain:0.8,release:0.24,
             tilt:-0.35,evolve:0.1),
        make("Warm Sub Sine","Bass","Simple restrained low-frequency sine tone.",
             harmonics:[0.95,0.18,0.06],
             attack:0.01,decay:0.22,sustain:0.88,release:0.29,
             tilt:-0.6,evolve:0),
        make("Plucked Overtones","Plucks","Fast spectral pluck with diminishing upper partials.",
             harmonics:[0.7,0.31,0.23,0.17,0.1,0.07,0.05,0.03],
             attack:0.001,decay:0.23,sustain:0.06,release:0.35,
             tilt:0.1,evolve:1.1,evolveTime:0.2),
        make("Harmonic Zither","Plucks","High, percussive partial shimmer.",
             harmonics:[0.56,0.08,0.43,0.12,0.29,0.09,0.21,0.04,0.13,0.04,0.08],
             attack:0.002,decay:0.5,sustain:0.05,release:1.15,
             tilt:0,evolve:0.85,evolveTime:0.35),
        make("Spectral Aurora","Textures","Bright attack dissolving into an evolving core.",
             harmonics:[0.42,0.17,0.28,0.06,0.23,0.04,0.18,0.02,
                        0.13,0.01,0.11,0.02,0.08,0.02,0.07,0.03],
             attack:0.4,decay:0.9,sustain:0.78,release:3.1,
             tilt:0,evolve:1.65,evolveTime:1.8),
        make("Evolving Hollow","Textures","Slow emergence of low harmonics.",
             harmonics:[0.7,0.05,0.44,0.02,0.21,0.01,0.12,0.01,0.05],
             attack:1.6,decay:1.1,sustain:0.87,release:3.6,
             tilt:-0.2,evolve:-1.2,evolveTime:3),
        make("Digital Prism","Textures","Dense inharmonic-like harmonic shimmer.",
             harmonics:[0.32,0.17,0.4,0.12,0.31,0.15,0.26,0.07,
                        0.22,0.09,0.18,0.06,0.15,0.04,0.12,0.03],
             attack:0.14,decay:0.55,sustain:0.72,release:2.4,
             tilt:-0.1,evolve:0.9,evolveTime:0.6)
    ]
}
