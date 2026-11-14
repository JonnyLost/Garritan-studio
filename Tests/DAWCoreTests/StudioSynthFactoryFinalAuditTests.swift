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
            XCTAssertEqual(patch.layers.filter(\.enabled).count,
                           patch.isHybrid ?
                            patch.layers.filter(\.enabled).count : 1)
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
