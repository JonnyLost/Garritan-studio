import Foundation

/// A first, self-contained granular factory bank. These sounds are generated
/// in native code: no commercial sample libraries or external audio required.
public struct StudioGranularPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let description: String
    public let patch: StudioGranularPatch
    public init(name: String, family: String, description: String,
                patch: StudioGranularPatch) {
        id="\(family.lowercased())-\(name.lowercased().replacingOccurrences(of:" ",with:"-"))"
        self.name=name
        self.family=family
        self.description=description
        self.patch=patch
    }
}
public enum StudioGranularFactoryLibrary {
    private static func make(_ name: String, _ family: String, _ description: String,
                             source: StudioGranularSource,
                             size: Float = 0.105, density: Float = 19,
                             position: Float = 0.45, scan: Float = 0,
                             pitch: Float = 0, pitchRandom: Float = 0.1,
                             positionRandom: Float = 0.08,
                             spread: Float = 0.5, attack: Float = 0.015,
                             release: Float = 0.32, reverse: Float = 0,
                             window: Float = 0.85) -> StudioGranularPreset {
        var patch=StudioGranularPatch()
        patch.source=source
        let controls:[(StudioGranularParameter,Float)] = [
            (.grainSize,size),(.density,density),(.position,position),
            (.scanSpeed,scan),(.pitch,pitch),(.pitchJitter,pitchRandom),
            (.positionJitter,positionRandom),(.panSpread,spread),
            (.attack,attack),(.release,release),(.reverse,reverse),
            (.window,window)
        ]
        for (key,value) in controls { patch.set(value,for:key) }
        return StudioGranularPreset(name:name,family:family,
                                    description:description,patch:patch)
    }
    public static let presets: [StudioGranularPreset] = [
        make("Cloud Lantern","Pads","Warm overlapping micrograins and slow movement.",
             source:.cloud,size:0.22,density:32,scan:0.02,
             spread:0.82,attack:0.62,release:2.4),
        make("String Dust","Pads","Soft floating string-like fragments.",
             source:.strings,size:0.18,density:28,
             positionRandom:0.22,spread:0.8,attack:0.55,release:3.1),
        make("Glass Atmosphere","Pads","Long sparkling microscopic bells.",
             source:.bells,size:0.16,density:38,scan:-0.045,
             pitchRandom:3.1,spread:0.94,attack:0.95,release:3.9),
        make("Ice Particles","Textures","Dense brittle crystal micrograins.",
             source:.bells,size:0.045,density:62,scan:0.19,
             pitch:7,pitchRandom:4,positionRandom:0.45,
             spread:1,attack:0.07,release:1.8),
        make("Tape Wind","Textures","Reverse-scanning high-density noise field.",
             source:.noise,size:0.11,density:48,scan:-0.17,
             positionRandom:0.54,spread:1,attack:0.27,release:2.1,
             reverse:0.85),
        make("Granular Tide","Textures","Slow panoramic harmonic drift.",
             source:.strings,size:0.38,density:17,scan:0.035,
             pitchRandom:1.2,positionRandom:0.32,
             spread:0.88,attack:0.9,release:4.4),
        make("Micro Organ","Keys","Tight short tonal slices for articulate phrases.",
             source:.cloud,size:0.07,density:35,spread:0.25,
             attack:0.003,release:0.23),
        make("Digital Marimba","Keys","Bell-like grains with short tails.",
             source:.bells,size:0.065,density:21,
             pitchRandom:0.2,positionRandom:0.05,
             spread:0.32,attack:0.002,release:0.42),
        make("Shifting Lead","Leads","Focused grain melody with slow pitch shimmer.",
             source:.strings,size:0.1,density:37,scan:0.12,
             pitchRandom:0.6,spread:0.35,attack:0.008,release:0.35),
        make("Swarm Signal","Leads","Unsteady swarm of detuned grain particles.",
             source:.cloud,size:0.035,density:77,scan:0.2,
             pitchRandom:5,positionRandom:0.3,
             spread:0.84,attack:0.025,release:0.5),
        make("Low Cloud","Bass","Short granular tone with a concentrated center.",
             source:.strings,size:0.16,density:28,
             pitch:-12,spread:0.12,attack:0.009,release:0.37),
        make("Sub Drift","Bass","Deep slowly scanning granular bass.",
             source:.cloud,size:0.25,density:30,scan:0.03,
             pitch:-12,pitchRandom:0.2,spread:0.35,
             attack:0.06,release:1.1)
    ]
}
