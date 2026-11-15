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
                "analog:factory.bass.sub-foundation",
                "analog:factory.bass.pulse-driver",
                "analog:factory.bass.acid-walk",
                "analog:factory.bass.deep-reese",
                "analog:factory.lead.classic-saw",
                "analog:factory.lead.pulse-solo",
                "analog:factory.lead.fifth-horizon",
                "analog:factory.lead.mellow-mono",
                "analog:factory.pad.warm-strings",
                "analog:factory.pad.air-bloom",
                "analog:factory.pad.slow-brass",
                "analog:factory.pad.luminous-fifths",
                "analog:factory.keys.analog-ep",
                "analog:factory.keys.dusty-keys",
                "analog:factory.keys.glass-organ",
                "analog:factory.keys.vintage-square",
                "analog:factory.pluck.copper-pluck",
                "analog:factory.pluck.wooden-click",
                "analog:factory.pluck.glass-droplet",
                "analog:factory.pluck.fifth-pluck",
                "analog:factory.texture.noise-wash",
                "analog:factory.texture.rising-fog",
                "analog:factory.texture.hollow-wind",
                "analog:factory.texture.motion-bed",
                "analog:factory.bass.obsidian-engine",
                "analog:factory.bass.round-trip",
                "analog:factory.lead.copper-sky",
                "analog:factory.lead.narrow-beam",
                "analog:factory.pad.midnight-strings",
                "analog:factory.pad.northern-lights",
                "analog:factory.keys.soft-circuit",
                "analog:factory.pluck.clockwork",
                "analog:factory.texture.signal-fog",
                "analog:factory.texture.ghost-machine",
            ],
            "FM": [
                "fm:factory.keys.aurora-electric",
                "fm:factory.keys.velvet-tines",
                "fm:factory.keys.crystal-stage",
                "fm:factory.keys.midnight-organ",
                "fm:factory.bells.starlight",
                "fm:factory.bells.silver-arc",
                "fm:factory.bells.temple-bronze",
                "fm:factory.bells.ice-pendant",
                "fm:factory.mallets.rosewood",
                "fm:factory.mallets.glass-marimba",
                "fm:factory.mallets.copper-keys",
                "fm:factory.mallets.satin-vibes",
                "fm:factory.bass.furnace-sub",
                "fm:factory.bass.fretless-current",
                "fm:factory.bass.digital-rubber",
                "fm:factory.bass.octave-circuit",
                "fm:factory.lead.neon-solo",
                "fm:factory.lead.hollow-signal",
                "fm:factory.lead.cobalt-edge",
                "fm:factory.lead.lyric-glass",
                "fm:factory.pad.lunar-choir",
                "fm:factory.pad.glacier-light",
                "fm:factory.pad.deep-atmosphere",
                "fm:factory.pad.harmonic-cloud",
                "fm:factory.percussion.steel-strike",
                "fm:factory.percussion.digital-wood",
                "fm:factory.percussion.glass-tick",
                "fm:factory.percussion.machine-pulse",
                "fm:factory.texture.nebula-veil",
                "fm:factory.texture.rust-horizon",
                "fm:factory.texture.frozen-orbit",
                "fm:factory.texture.chromatic-drift",
                "fm:factory.keys.satin-electric",
                "fm:factory.keys.silver-steps",
                "fm:factory.bells.orbit-bell",
                "fm:factory.mallets.bamboo-drops",
                "fm:factory.bass.reactor-low",
                "fm:factory.bass.deep-quartz",
                "fm:factory.lead.arc-light",
                "fm:factory.pad.halo-choir",
                "fm:factory.texture.glass-storm",
                "fm:factory.percussion.circuit-clack",
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
