import XCTest
import Foundation
@testable import DAWUI
import DAWCore

final class StudioSynthFactoryCatalogTests: XCTestCase {
    func testEveryNativeEngineFamilyIsAvailable() {
        let sounds = StudioSynthFactoryCatalog.sounds
        let engines = Set(sounds.map(\.engineName))
        XCTAssertEqual(engines, Set([
            "Analog", "FM", "Wavetable", "Additive",
            "Granular", "Physical Modeling", "Hybrid"
        ]))
        XCTAssertFalse(sounds.isEmpty)
    }

    func testFactoryIndexReflectsOriginalPresetLibraries() {
        let sounds = StudioSynthFactoryCatalog.sounds
        XCTAssertEqual(sounds.filter { $0.engineName == "Analog" }.count,
                       StudioAnalogFactoryLibrary.presets.count)
        XCTAssertEqual(sounds.filter { $0.engineName == "FM" }.count,
                       StudioFMFactoryLibrary.presets.count)
        XCTAssertEqual(sounds.filter { $0.engineName == "Wavetable" }.count,
                       StudioWavetableFactoryLibrary.presets.count)
        XCTAssertEqual(sounds.filter { $0.engineName == "Additive" }.count,
                       StudioAdditiveFactoryLibrary.presets.count)
        XCTAssertEqual(sounds.filter { $0.engineName == "Granular" }.count,
                       StudioGranularFactoryLibrary.presets.count)
        XCTAssertEqual(sounds.filter { $0.engineName == "Physical Modeling" }.count,
                       StudioPhysicalFactoryLibrary.presets.count)
        XCTAssertEqual(sounds.filter { $0.engineName == "Hybrid" }.count,
                       StudioSynthHybridFactoryLibrary.presets.count)
    }

    func testAllNativeSoundsHaveStableUniqueIdentifiersAndResolvablePatches() {
        let sounds = StudioSynthFactoryCatalog.sounds
        XCTAssertEqual(Set(sounds.map(\.id)).count, sounds.count)
        for sound in sounds {
            XCTAssertEqual(StudioSynthFactoryCatalog.sound(id: sound.id)?.name,
                           sound.name, "Unresolvable preset: \(sound.id)")
            XCTAssertEqual(sound.instrumentPath.split(separator: "/").first, "Synth")
            XCTAssertEqual(sound.instrumentPath.split(separator: "/").count, 4)
            XCTAssertFalse(sound.category.isEmpty)
            XCTAssertTrue(sound.patch.validate(), "Invalid native patch: \(sound.id)")
        }
    }

    func testHybridFactoryModulationRoutesFollowFreshLayerIdentities() {
        for sound in StudioSynthFactoryCatalog.sounds where sound.engineName == "Hybrid" {
            let instance = sound.instantiatePatch()
            XCTAssertTrue(instance.validate(), "Invalid instantiated Hybrid: \(sound.id)")
            for route in instance.modulation?.routes ?? [] {
                XCTAssertTrue(instance.layers.contains { $0.id == route.layerID },
                              "Dangling modulation route: \(sound.id)")
            }
        }
    }

    func testFactoryPatchIsCopiedIntoTrackWithoutSharedIdentity() {
        guard let sound = StudioSynthFactoryCatalog.sounds.first else {
            XCTFail("No factory sounds")
            return
        }
        let first = sound.instantiatePatch()
        let second = sound.instantiatePatch()
        XCTAssertTrue(first.validate())
        XCTAssertTrue(second.validate())
        XCTAssertNotEqual(first.layers.first?.id, second.layers.first?.id,
                          "Each factory selection must create its own voice-layer identity")
    }

    func testStableFactoryInventoryAndCategories() {
        // Deliberate release manifest: renaming/reclassifying a factory sound
        // must not silently change the identity used by the instrument picker.
        let expected: [String: [String]] = [
            "Analog": [
                "analog:bass.sub-foundation",
                "analog:bass.pulse-driver",
                "analog:bass.acid-walk",
                "analog:bass.deep-reese",
                "analog:lead.classic-saw",
                "analog:lead.pulse-solo",
                "analog:lead.fifth-horizon",
                "analog:lead.mellow-mono",
                "analog:pad.warm-strings",
                "analog:pad.air-bloom",
                "analog:pad.slow-brass",
                "analog:pad.luminous-fifths",
                "analog:keys.analog-ep",
                "analog:keys.dusty-keys",
                "analog:keys.glass-organ",
                "analog:keys.vintage-square",
                "analog:pluck.copper-pluck",
                "analog:pluck.wooden-click",
                "analog:pluck.glass-droplet",
                "analog:pluck.fifth-pluck",
                "analog:texture.noise-wash",
                "analog:texture.rising-fog",
                "analog:texture.hollow-wind",
                "analog:texture.motion-bed",
                "analog:bass.obsidian-engine",
                "analog:bass.round-trip",
                "analog:lead.copper-sky",
                "analog:lead.narrow-beam",
                "analog:pad.midnight-strings",
                "analog:pad.northern-lights",
                "analog:keys.soft-circuit",
                "analog:pluck.clockwork",
                "analog:texture.signal-fog",
                "analog:texture.ghost-machine",
            ],
            "FM": [
                "fm:keys.aurora-electric",
                "fm:keys.velvet-tines",
                "fm:keys.crystal-stage",
                "fm:keys.midnight-organ",
                "fm:bells.starlight",
                "fm:bells.silver-arc",
                "fm:bells.temple-bronze",
                "fm:bells.ice-pendant",
                "fm:mallets.rosewood",
                "fm:mallets.glass-marimba",
                "fm:mallets.copper-keys",
                "fm:mallets.satin-vibes",
                "fm:bass.furnace-sub",
                "fm:bass.fretless-current",
                "fm:bass.digital-rubber",
                "fm:bass.octave-circuit",
                "fm:lead.neon-solo",
                "fm:lead.hollow-signal",
                "fm:lead.cobalt-edge",
                "fm:lead.lyric-glass",
                "fm:pad.lunar-choir",
                "fm:pad.glacier-light",
                "fm:pad.deep-atmosphere",
                "fm:pad.harmonic-cloud",
                "fm:percussion.steel-strike",
                "fm:percussion.digital-wood",
                "fm:percussion.glass-tick",
                "fm:percussion.machine-pulse",
                "fm:texture.nebula-veil",
                "fm:texture.rust-horizon",
                "fm:texture.frozen-orbit",
                "fm:texture.chromatic-drift",
                "fm:keys.satin-electric",
                "fm:keys.silver-steps",
                "fm:bells.orbit-bell",
                "fm:mallets.bamboo-drops",
                "fm:bass.reactor-low",
                "fm:bass.deep-quartz",
                "fm:lead.arc-light",
                "fm:pad.halo-choir",
                "fm:texture.glass-storm",
                "fm:percussion.circuit-clack",
            ],
            "Wavetable": [
                "wavetable:keys-blue-tines",
                "wavetable:keys-crystal-harp",
                "wavetable:keys-motion-keys",
                "wavetable:keys-glass-pluck",
                "wavetable:lead-aurora-line",
                "wavetable:lead-copper-pulse",
                "wavetable:lead-prism-edge",
                "wavetable:lead-horizon-solo",
                "wavetable:pad-lunar-drift",
                "wavetable:pad-glacier-choir",
                "wavetable:pad-satellite-mist",
                "wavetable:pad-warm-cosmos",
                "wavetable:bass-iron-current",
                "wavetable:bass-substructure",
                "wavetable:bass-rubber-circuit",
                "wavetable:bass-neon-throb",
                "wavetable:texture-ice-constellation",
                "wavetable:texture-ribbon-atmosphere",
                "wavetable:texture-meteor-dust",
                "wavetable:texture-harmonic-ocean",
                "wavetable:keys-midnight-glass",
                "wavetable:keys-velvet-phase",
                "wavetable:lead-solar-flare",
                "wavetable:lead-hollow-beacon",
                "wavetable:pad-polar-silk",
                "wavetable:pad-cathedral-air",
                "wavetable:bass-carbon-pulse",
                "wavetable:bass-undercurrent",
                "wavetable:texture-starfield-dust",
                "wavetable:texture-tidal-spectrum",
            ],
            "Additive": [
                "additive:keys-pure-foundation",
                "additive:keys-bell-keys",
                "additive:keys-tine-spark",
                "additive:winds-hollow-reed",
                "additive:winds-silver-flute",
                "additive:winds-brass-outline",
                "additive:pads-warm-string-bed",
                "additive:pads-glass-bloom",
                "additive:pads-deep-choir-cloud",
                "additive:bass-octave-pillar",
                "additive:bass-warm-sub-sine",
                "additive:plucks-plucked-overtones",
                "additive:plucks-harmonic-zither",
                "additive:textures-spectral-aurora",
                "additive:textures-evolving-hollow",
                "additive:textures-digital-prism",
                "additive:keys-celestial-celesta",
                "additive:keys-soft-tine-choir",
                "additive:winds-breath-organ",
                "additive:winds-reed-harmonics",
                "additive:strings-amber-ensemble",
                "additive:strings-silk-harmonics",
                "additive:bass-sub-harmonic",
                "additive:brass-granite-brass",
                "additive:textures-solar-filaments",
                "additive:textures-harmonic-rain",
            ],
            "Granular": [
                "granular:pads-cloud-lantern",
                "granular:pads-string-dust",
                "granular:pads-glass-atmosphere",
                "granular:textures-ice-particles",
                "granular:textures-tape-wind",
                "granular:textures-granular-tide",
                "granular:keys-micro-organ",
                "granular:keys-digital-marimba",
                "granular:leads-shifting-lead",
                "granular:leads-swarm-signal",
                "granular:bass-low-cloud",
                "granular:bass-sub-drift",
                "granular:pads-aurora-veil",
                "granular:pads-vapor-cathedral",
                "granular:textures-crystal-rain",
                "granular:textures-black-sand",
                "granular:textures-reverse-halo",
                "granular:keys-copper-fragments",
                "granular:keys-pulsing-tape",
                "granular:leads-frost-signal",
                "granular:bass-deep-engine",
                "granular:bass-undersea-current",
            ],
            "Physical Modeling": [
                "physical:strings-warm-nylon",
                "physical:strings-bright-steel",
                "physical:keys-felt-hammer",
                "physical:strings-bow-resonance",
                "physical:winds-reed-chamber",
                "physical:brass-open-brass",
                "physical:percussion-soft-marimba",
                "physical:percussion-bright-xylophone",
                "physical:percussion-silver-bell",
                "physical:percussion-bronze-chime",
                "physical:percussion-kettle-skin",
                "physical:percussion-short-tom",
                "physical:strings-fingerstyle-cedar",
                "physical:strings-mandolin-spark",
                "physical:keys-felt-upright",
                "physical:keys-hard-hammer",
                "physical:strings-soft-bow",
                "physical:strings-rosin-edge",
                "physical:winds-dark-clarinet",
                "physical:winds-bright-oboe",
                "physical:brass-mellow-horn",
                "physical:brass-bright-fanfare",
                "physical:percussion-woodblock-bloom",
                "physical:percussion-temple-gong",
                "physical:percussion-low-timpani",
            ],
            "Hybrid": [
                "hybrid:cinematic-orchestral-vapor",
                "hybrid:cinematic-glass-horizon",
                "hybrid:cinematic-dark-choir",
                "hybrid:pads-spectral-morning",
                "hybrid:pads-prism-drift",
                "hybrid:keys-tine-and-bell",
                "hybrid:keys-pure-spectrum-keys",
                "hybrid:bass-bass-cathedral",
                "hybrid:textures-timbre-atlas",
                "hybrid:cinematic-plucked-atmosphere",
                "hybrid:keys-resonant-bronze",
                "hybrid:textures-fourfold-spectrum",
                "hybrid:cinematic-eclipse-strings",
                "hybrid:cinematic-bronze-cathedral",
                "hybrid:cinematic-frosted-orchestra",
                "hybrid:textures-night-signal",
                "hybrid:textures-crystal-engine",
                "hybrid:pads-oceanic-choir",
                "hybrid:leads-voltage-horizon",
                "hybrid:keys-resonant-cedar",
                "hybrid:bass-low-orbit",
                "hybrid:cinematic-starlight-resonator",
            ],
        ]
        let sounds = StudioSynthFactoryCatalog.sounds
        XCTAssertEqual(sounds.count, 201)
        for (engine, ids) in expected {
            XCTAssertEqual(Set(sounds.filter { $0.engineName == engine }.map(\.id)),
                           Set(ids), engine)
        }
        for sound in sounds {
            XCTAssertFalse(sound.summary.isEmpty, sound.id)
            if sound.engineName != "Hybrid" {
                XCTAssertEqual(sound.patch.layers.count, 1, sound.id)
                let engine = sound.patch.layers[0].engine
                XCTAssertEqual(engine == .physical ? "Physical Modeling" : engine.title,
                               sound.engineName, sound.id)
            }
        }
    }

    @MainActor
    func testEveryPickerPresetLoadsNativeInstrumentAndEditedTrackRoundTrips() throws {
        for sound in StudioSynthFactoryCatalog.sounds {
            var patch = sound.instantiatePatch()
            // Exercise actual native engine/resource construction, including
            // all Hybrid combinations, without depending on an audio device.
            let instrument = try StudioSynthInstrument(sampleRate: 44_100, patch: patch)
            XCTAssertTrue(instrument.allNotesOff(), sound.id)
            patch.layers[0].gain = 0.37
            patch.layers[0].pan = -0.23
            var track = Track(name: sound.name, type: .instrument)
            track.studioSynthEnabled = true
            track.studioSynthPatch = patch
            let restored = try JSONDecoder().decode(Track.self,
                from: JSONEncoder().encode(track))
            XCTAssertEqual(restored.studioSynthEnabled, true, sound.id)
            XCTAssertEqual(restored.studioSynthPatch, patch, sound.id)
            XCTAssertNotEqual(StudioSynthFactoryCatalog.sound(id: sound.id)?.patch.layers[0].gain,
                              patch.layers[0].gain, sound.id)
        }
    }
}
