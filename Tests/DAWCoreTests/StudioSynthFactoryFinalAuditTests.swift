import XCTest
import Foundation
@testable import DAWCore

/// A single acceptance gate for the unified factory browser. Every factory
/// sound must be loadable as a native Studio Synth layer and survive project
/// serialization without third-party Audio Units or a legacy plug-in host.
@MainActor
final class StudioSynthFactoryFinalAuditTests: XCTestCase {
    private func verify(_ patches: [(String, StudioSynthPatch)],
                        category: String) throws {
        XCTAssertFalse(patches.isEmpty, "Missing \(category) factory sounds")
        for (name, patch) in patches {
            XCTAssertTrue(patch.validate(), "\(category): \(name)")
            XCTAssertTrue((1...4).contains(patch.layers.filter(\.enabled).count))
            let reopened = try JSONDecoder().decode(
                StudioSynthPatch.self, from: JSONEncoder().encode(patch))
            XCTAssertEqual(reopened, patch, "\(category): \(name)")
        }
    }

    func testEveryNativeFactorySoundIsValidAndProjectSerializable() throws {
        try verify(StudioAnalogFactoryLibrary.presets.map { preset in
            (preset.name, StudioSynthPatch(layers: [
                StudioSynthLayer(engine: .analog, analogPatch: preset.patch)
            ]))
        }, category: "Analog")

        try verify(StudioFMFactoryLibrary.presets.map { preset in
            (preset.name, StudioSynthPatch(layers: [
                StudioSynthLayer(engine: .fm, fmPatch: preset.patch)
            ]))
        }, category: "FM")

        try verify(StudioWavetableFactoryLibrary.presets.map { preset in
            (preset.name, StudioSynthPatch(layers: [
                StudioSynthLayer(engine: .wavetable,
                                 wavetablePatch: preset.patch)
            ]))
        }, category: "Wavetable")

        try verify(StudioAdditiveFactoryLibrary.presets.map { preset in
            (preset.name, StudioSynthPatch(layers: [
                StudioSynthLayer(engine: .additive,
                                 additivePatch: preset.patch)
            ]))
        }, category: "Additive")

        try verify(StudioGranularFactoryLibrary.presets.map { preset in
            (preset.name, StudioSynthPatch(layers: [
                StudioSynthLayer(engine: .granular,
                                 granularPatch: preset.patch)
            ]))
        }, category: "Granular")

        try verify(StudioPhysicalFactoryLibrary.presets.map { preset in
            (preset.name, StudioSynthPatch(layers: [
                StudioSynthLayer(engine: .physical,
                                 physicalPatch: preset.patch)
            ]))
        }, category: "Physical")

        try verify(StudioSynthHybridFactoryLibrary.presets.map {
            ($0.name, $0.patch)
        }, category: "Hybrid")
    }

    /// The expanded bank is part of the native app, not a downloaded or
    /// licensed library. Protect the breadth of each sound category.
    func testExpandedFactoryBankContainsExactly201OriginalSounds() {
        let counts: [(String, Int, Int)] = [
            ("Analog", StudioAnalogFactoryLibrary.presets.count, 34),
            ("FM", StudioFMFactoryLibrary.presets.count, 42),
            ("Wavetable", StudioWavetableFactoryLibrary.presets.count, 30),
            ("Additive", StudioAdditiveFactoryLibrary.presets.count, 26),
            ("Granular", StudioGranularFactoryLibrary.presets.count, 22),
            ("Physical", StudioPhysicalFactoryLibrary.presets.count, 25),
            ("Hybrid", StudioSynthHybridFactoryLibrary.presets.count, 22)
        ]
        for (engine, actual, expected) in counts {
            XCTAssertEqual(actual, expected, engine)
        }
        XCTAssertEqual(counts.reduce(0) { $0 + $1.1 }, 201)
    }

    func testEveryHybridSoundContainsTwoToFourNativeLayers() {
        for preset in StudioSynthHybridFactoryLibrary.presets {
            XCTAssertTrue((2...4).contains(preset.patch.layers.count),
                          preset.name)
            XCTAssertEqual(preset.patch.layers.count,
                           preset.patch.layers.filter(\.enabled).count,
                           preset.name)
            XCTAssertTrue(preset.patch.validate(), preset.name)
        }
    }

    func testHybridEmbeddedFactoryReferencesResolveWithoutDefaultFallback() {
        for preset in StudioSynthHybridFactoryLibrary.presets {
            for layer in preset.patch.layers {
                if layer.engine == .additive {
                    XCTAssertTrue(StudioAdditiveFactoryLibrary.presets.contains {
                        $0.patch == layer.additivePatch
                    }, "Unresolved Additive recipe in \(preset.name)")
                }
                if layer.engine == .physical {
                    XCTAssertTrue(StudioPhysicalFactoryLibrary.presets.contains {
                        $0.patch == layer.physicalPatch
                    }, "Unresolved Physical recipe in \(preset.name)")
                }
            }
        }
    }

    func testAllFactoryNamesAndIDsAreUnambiguousWithinTheirBrowser() {
        let families: [(String, [String], [String])] = [
            ("Analog",
             StudioAnalogFactoryLibrary.presets.map(\.id),
             StudioAnalogFactoryLibrary.presets.map(\.name)),
            ("FM",
             StudioFMFactoryLibrary.presets.map(\.id),
             StudioFMFactoryLibrary.presets.map(\.name)),
            ("Wavetable",
             StudioWavetableFactoryLibrary.presets.map(\.id),
             StudioWavetableFactoryLibrary.presets.map(\.name)),
            ("Additive",
             StudioAdditiveFactoryLibrary.presets.map(\.id),
             StudioAdditiveFactoryLibrary.presets.map(\.name)),
            ("Granular",
             StudioGranularFactoryLibrary.presets.map(\.id),
             StudioGranularFactoryLibrary.presets.map(\.name)),
            ("Physical",
             StudioPhysicalFactoryLibrary.presets.map(\.id),
             StudioPhysicalFactoryLibrary.presets.map(\.name)),
            ("Hybrid",
             StudioSynthHybridFactoryLibrary.presets.map(\.id),
             StudioSynthHybridFactoryLibrary.presets.map(\.name))
        ]
        for (family, ids, names) in families {
            XCTAssertEqual(Set(ids).count, ids.count, family)
            XCTAssertEqual(Set(names.map { $0.lowercased() }).count,
                           names.count, family)
            XCTAssertFalse(names.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }), family)
        }
    }
}
