import XCTest
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
}
