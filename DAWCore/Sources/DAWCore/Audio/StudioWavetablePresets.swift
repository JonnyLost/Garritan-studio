import Foundation

/// Original mathematically generated Studio Wavetable patches. They contain
/// synthesis parameters and harmonics only—no commercial samples, wavetables
/// or licensed audio content.
public struct StudioWavetablePreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let summary: String
    public let patch: StudioWavetablePatch

    public init(name: String, family: String, summary: String,
                patch: StudioWavetablePatch) {
        self.id = "\(family.lowercased())-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        self.name = name
        self.family = family
        self.summary = summary
        self.patch = patch
    }
}

/// The initial wavetable bank uses 20 uniquely parameterized sound recipes.
public enum StudioWavetableFactoryLibrary {
    private static func make(
        _ name: String, _ family: String, _ summary: String,
        pos1: Float, pos2: Float, level1: Float, level2: Float,
        detune: Float = 0, attack: Float = 0.005, decay: Float = 0.25,
        sustain: Float = 0.7, release: Float = 0.25,
        lfoRate: Float = 0.5, lfoDepth: Float = 0,
        velocity: Float = 0, wheel: Float = 0,
        partials: [Float] = []
    ) -> StudioWavetablePreset {
        var p = StudioWavetablePatch()
        let values: [(StudioWavetableParameter, Float)] = [
            (.osc1Position,pos1),(.osc2Position,pos2),
            (.osc1Level,level1),(.osc2Level,level2),
            (.osc2Detune,detune),
            (.attack,attack),(.decay,decay),(.sustain,sustain),
            (.release,release),(.lfoRate,lfoRate),(.lfoDepth,lfoDepth),
            (.velocityPosition,velocity),(.modWheelPosition,wheel)
        ]
        for (parameter,value) in values { p.set(value, for: parameter) }
        for (index, amplitude) in partials.enumerated() {
            if let param = StudioWavetableParameter.partial(index) {
                p.set(amplitude, for: param)
            }
        }
        return StudioWavetablePreset(name: name, family: family,
                                      summary: summary, patch: p)
    }

    public static let presets: [StudioWavetablePreset] = [
        // Keys
        make("Blue Tines", "Keys", "Gentle glass-like keyboard with a long tail.",
             pos1: 3.8,pos2: 0.6,level1: 0.7,level2: 0.12,detune: 0.05,
             decay: 0.75,sustain: 0.18,release: 1.4,velocity: 0.45),
        make("Crystal Harp", "Keys", "Bright struck partials with subtle morph.",
             pos1: 4.4,pos2: 0,level1: 0.82,level2: 0.08,detune: 12,
             decay: 0.9,sustain: 0.1,release: 1.6,wheel: 0.4),
        make("Motion Keys", "Keys", "Animated electric keyboard foundation.",
             pos1: 1.8,pos2: 2.6,level1: 0.65,level2: 0.24,detune: 0.12,
             decay: 0.35,sustain: 0.56,release: 0.48,lfoRate: 0.8,
             lfoDepth: 0.16),
        make("Glass Pluck", "Keys", "Sparse, sharp spectral attack.",
             pos1: 4.9,pos2: 3.4,level1: 0.8,level2: 0.06,
             decay: 0.16,sustain: 0,release: 0.32,velocity: 0.9,
             partials: [0.7,0.1,0.1,0,0.75,0,0,0.4]),

        // Leads
        make("Aurora Line", "Lead", "Rounded expressive wavetable lead.",
             pos1: 1.8,pos2: 2.4,level1: 0.7,level2: 0.24,detune: 0.09,
             attack: 0.025,decay: 0.2,sustain: 0.86,release: 0.32,
             lfoDepth: 0.12,wheel: 0.7),
        make("Copper Pulse", "Lead", "Strong square/saw transition.",
             pos1: 2.9,pos2: 3.3,level1: 0.75,level2: 0.16,detune: 0.04,
             sustain: 0.92,release: 0.12,velocity: 0.5),
        make("Prism Edge", "Lead", "Evolving glass-harmonic solo.",
             pos1: 4.1,pos2: 3.9,level1: 0.72,level2: 0.2,detune: 0.07,
             attack: 0.015,decay: 0.25,sustain: 0.78,release: 0.5,
             lfoRate: 4.8,lfoDepth: 0.25,wheel: 0.9),
        make("Horizon Solo", "Lead", "Smooth fundamental with moving upper spectrum.",
             pos1: 0.8,pos2: 4.3,level1: 0.6,level2: 0.32,detune: 0.05,
             attack: 0.035,sustain: 0.84,release: 0.38,
             lfoRate: 0.35,lfoDepth: 0.15),

        // Pads
        make("Lunar Drift", "Pad", "Slow evolving glass and triangle layers.",
             pos1: 4.2,pos2: 1.2,level1: 0.58,level2: 0.37,detune: 0.13,
             attack: 2,decay: 1.7,sustain: 0.76,release: 3.5,
             lfoRate: 0.15,lfoDepth: 0.42,wheel: 0.6),
        make("Glacier Choir", "Pad", "Airy spectral motion with gentle fifths.",
             pos1: 3.9,pos2: 0.8,level1: 0.6,level2: 0.29,detune: 7,
             attack: 1.2,decay: 1.6,sustain: 0.8,release: 4,
             lfoRate: 0.23,lfoDepth: 0.3),
        make("Satellite Mist", "Pad", "Very soft ribbon-like digital wash.",
             pos1: 0.7,pos2: 2.1,level1: 0.52,level2: 0.34,detune: 0.08,
             attack: 3,decay: 2.1,sustain: 0.8,release: 5,
             lfoRate: 0.09,lfoDepth: 0.55,wheel: 0.35),
        make("Warm Cosmos", "Pad", "Slow harmonic organ swell.",
             pos1: 2.2,pos2: 2.8,level1: 0.57,level2: 0.32,detune: -0.08,
             attack: 1.4,decay: 1,sustain: 0.91,release: 3.2,
             lfoRate: 0.38,lfoDepth: 0.24),

        // Bass
        make("Iron Current", "Bass", "Focused square/saw bass.",
             pos1: 2.5,pos2: 3,level1: 0.77,level2: 0.2,
             decay: 0.19,sustain: 0.68,release: 0.17,velocity: 0.3),
        make("Substructure", "Bass", "Rounded low-frequency foundation.",
             pos1: 0.6,pos2: 1.3,level1: 0.78,level2: 0.16,detune: -12,
             decay: 0.25,sustain: 0.75,release: 0.24),
        make("Rubber Circuit", "Bass", "Elastic harmonic attack and short release.",
             pos1: 3.1,pos2: 2.8,level1: 0.83,level2: 0.16,
             decay: 0.12,sustain: 0.47,release: 0.12,velocity: 0.8,
             lfoRate: 1.4,lfoDepth: 0.18),
        make("Neon Throb", "Bass", "Pulse-driven modulating bass.",
             pos1: 1.8,pos2: 3.6,level1: 0.69,level2: 0.27,detune: 0.13,
             decay: 0.5,sustain: 0.69,release: 0.28,
             lfoRate: 2.6,lfoDepth: 0.32),

        // Textures
        make("Ice Constellation", "Texture", "Sparse upper partials from a custom spectrum.",
             pos1: 5,pos2: 4.4,level1: 0.63,level2: 0.2,detune: 0.21,
             attack: 0.8,decay: 2,sustain: 0.4,release: 4,
             lfoRate: 0.18,lfoDepth: 0.3,
             partials: [0.35,0,0.1,0,0.85,0,0.35,0,0.22,0,0.16]),
        make("Ribbon Atmosphere", "Texture", "Crossfade from sine to complex spectra.",
             pos1: 1.2,pos2: 4.2,level1: 0.49,level2: 0.41,detune: 0.19,
             attack: 2,decay: 2.5,sustain: 0.75,release: 5,
             lfoRate: 0.11,lfoDepth: 0.72,wheel: 0.7),
        make("Meteor Dust", "Texture", "Percussive spectral particles.",
             pos1: 4.7,pos2: 5,level1: 0.74,level2: 0.13,detune: 12,
             decay: 0.11,sustain: 0.04,release: 0.7,
             lfoRate: 7,lfoDepth: 0.4,velocity: 1,
             partials: [0.2,0.1,0,0,0.8,0.2,0.5,0.2,0.1]),
        make("Harmonic Ocean", "Texture", "Slowly drifting warm spectral swells.",
             pos1: 4.8,pos2: 2.9,level1: 0.57,level2: 0.34,detune: -0.12,
             attack: 2.5,decay: 2.1,sustain: 0.78,release: 4.8,
             lfoRate: 0.07,lfoDepth: 0.6,wheel: -0.45,
             partials: [0.7,0.25,0.4,0.12,0.35,0.1,0.2])
    ]
}
