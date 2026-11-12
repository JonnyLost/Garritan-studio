import Foundation
import AVFoundation
import XCTest
@testable import DAWCore

@MainActor
final class StudioFMPresetLibraryTests: XCTestCase {
    func testAllFactoryPatchesAreDistinctValidAndApplyToDSP() throws {
        let presets = StudioFMFactoryLibrary.presets
        XCTAssertEqual(presets.count, 32)
        XCTAssertEqual(Set(presets.map(\.id)).count, 32)
        XCTAssertEqual(Set(presets.map(\.name)).count, 32)
        XCTAssertEqual(Set(presets.map(\.patch)).count, 32)
        XCTAssertEqual(Set(presets.map(\.category)),
                       Set(StudioFMPresetCategory.allCases))
        for category in StudioFMPresetCategory.allCases {
            XCTAssertEqual(presets.filter { $0.category == category }.count, 4,
                           "Expected four original sounds in \(category.title)")
        }
        let algorithmNumbers = Set(presets.map { Int($0.patch.value(for: .algorithm)) })
        XCTAssertEqual(algorithmNumbers, Set(StudioFMAlgorithm.allCases.map(\.rawValue)))

        let synth = try StudioFMInstrument(sampleRate: 44_100)
        for preset in presets {
            XCTAssertEqual(preset.origin, .factory)
            XCTAssertNoThrow(try preset.validate(), preset.name)
            XCTAssertNoThrow(try synth.apply(preset.patch), preset.name)
            for parameter in StudioFMParameter.allCases {
                let value = preset.patch.value(for: parameter)
                XCTAssertTrue(parameter.valid(value),
                              "\(preset.name) has invalid \(parameter)")
                XCTAssertEqual(synth.parameter(parameter), value,
                               accuracy: 0.0001, "\(preset.name), \(parameter)")
            }
        }
    }

    func testUserPresetsSaveReloadDeleteAndKeepEmbeddedProjectSound() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-user-presets-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bank = StudioFMPresetStore(directory: folder)
        XCTAssertTrue(try bank.loadUserPresets().presets.isEmpty)

        var patch = StudioFMPatch()
        patch.set(1, for: .algorithm)
        patch.set(2.37, for: .op2Ratio)
        patch.set(0.48, for: .op3Level)
        patch.set(0.6, for: .feedback)
        let saved = try bank.save(name: "  My Electric Keys  ",
                                  summary: "Original homemade FM patch",
                                  category: .keys, patch: patch)
        XCTAssertEqual(saved.name, "My Electric Keys")
        XCTAssertEqual(saved.origin, .user)
        XCTAssertNoThrow(try saved.validate())
        XCTAssertEqual(try bank.loadUserPresets().presets, [saved])
        XCTAssertTrue(try bank.loadUserPresets().skippedFiles.isEmpty)

        var track = Track(name: "FM Track", type: .instrument)
        track.studioFMEnabled = true
        track.studioFMPatch = saved.patch
        track.studioFMPresetID = saved.id
        let projectCopy = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(projectCopy.studioFMPresetID, saved.id)
        XCTAssertEqual(projectCopy.studioFMPatch, saved.patch)
        let synth = try StudioFMInstrument(sampleRate: 44_100)
        try synth.apply(try XCTUnwrap(projectCopy.studioFMPatch))
        XCTAssertEqual(synth.parameter(.op2Ratio), 2.37, accuracy: 0.0001)

        try bank.delete(saved)
        XCTAssertTrue(try bank.loadUserPresets().presets.isEmpty)
        XCTAssertEqual(projectCopy.studioFMPatch, patch,
                       "Deleting user bank files cannot alter saved projects")
        XCTAssertThrowsError(try bank.delete(StudioFMFactoryLibrary.presets[0]))
    }

    func testMalformedPresetsAreIsolatedAndValidationProtectsDSP() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-corrupt-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bank = StudioFMPresetStore(directory: folder)
        let kept = try bank.save(name: "Kept", summary: "", category: .lead,
                                 patch: StudioFMPatch())
        let damaged = folder.appendingPathComponent("bad.studiofm.json")
        try Data("{ this is not json }".utf8).write(to: damaged)
        let loaded = try bank.loadUserPresets()
        XCTAssertEqual(loaded.presets, [kept])
        XCTAssertEqual(loaded.skippedFiles, [damaged.lastPathComponent])

        var unknown = StudioFMPatch()
        unknown.values["9999"] = 0.5
        XCTAssertThrowsError(try bank.save(name: "Bad ID", summary: "",
                                            category: .bass, patch: unknown))
        unknown = StudioFMPatch()
        unknown.values["5"] = .infinity
        XCTAssertThrowsError(try bank.save(name: "Bad Number", summary: "",
                                            category: .bass, patch: unknown))
        XCTAssertThrowsError(try bank.save(name: "  ", summary: "",
                                            category: .bells, patch: .init()))
        XCTAssertThrowsError(try bank.save(name: String(repeating: "x", count: 81),
                                            summary: "", category: .bells,
                                            patch: .init()))
        var future = StudioFMPatch()
        future.version = 2
        XCTAssertThrowsError(try bank.save(name: "Future", summary: "",
                                            category: .keys, patch: future))
    }

    func testLegacyTrackPreservesOldInstrumentWithoutFMSelection() throws {
        var track = Track(name: "ARIA from old project", type: .instrument)
        track.studioAnalogEnabled = true
        let original = try JSONEncoder().encode(track)
        var oldJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any])
        oldJSON.removeValue(forKey: "studioFMEnabled")
        oldJSON.removeValue(forKey: "studioFMPatch")
        oldJSON.removeValue(forKey: "studioFMPresetID")
        let oldTrack = try JSONDecoder().decode(
            Track.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(oldTrack.studioFMEnabled)
        XCTAssertNil(oldTrack.studioFMPatch)
        XCTAssertNil(oldTrack.studioFMPresetID)
        XCTAssertEqual(oldTrack.studioAnalogEnabled, true)
    }
}
