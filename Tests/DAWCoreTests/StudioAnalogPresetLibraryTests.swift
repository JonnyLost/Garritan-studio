import Foundation
import XCTest
@testable import DAWCore

final class StudioAnalogPresetLibraryTests: XCTestCase {
    func testFactoryLibraryHasTwentyFourValidUniqueOriginalSounds() throws {
        let presets = StudioAnalogFactoryLibrary.presets
        XCTAssertEqual(presets.count, 24)
        XCTAssertEqual(Set(presets.map(\.id)).count, 24)
        XCTAssertEqual(Set(presets.map(\.name)).count, 24)
        XCTAssertEqual(Set(presets.map(\.category)), Set(StudioAnalogPresetCategory.allCases))
        for preset in presets {
            XCTAssertEqual(preset.origin, .factory)
            XCTAssertNoThrow(try preset.validate(), preset.name)
            for parameter in StudioAnalogParameter.allCases {
                XCTAssertTrue(parameter.valid(preset.patch.value(for: parameter)),
                              "\(preset.name): \(parameter)")
            }
            // Factory patches must be compatible with the real C++ graph
            // compiler, not merely with the Swift UI cable-type validator.
            let synth = try StudioAnalogInstrument(sampleRate: 44_100)
            XCTAssertNoThrow(try synth.setRouting(preset.patch.activeConnections),
                             preset.name)
            synth.apply(preset.patch)
        }
    }

    func testUserPresetSaveLoadDeleteAndProjectIndependentPatch() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-analog-presets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = StudioAnalogPresetStore(directory: temporary)
        XCTAssertTrue(try store.loadUserPresets().presets.isEmpty)
        var patch = StudioAnalogPatch()
        patch.set(1234, for: .filterCutoff)
        patch.set(0.36, for: .modulationDepth)
        patch.connections = StudioAnalogConnection.factory
        let saved = try store.save(name: "  My Shimmer  ", summary: "An original sound",
                                   category: .pad, patch: patch)
        XCTAssertEqual(saved.name, "My Shimmer")
        XCTAssertEqual(saved.origin, .user)
        XCTAssertEqual(try store.loadUserPresets().presets, [saved])
        XCTAssertEqual(try store.loadUserPresets().presets.first?.patch, patch)

        var track = Track(name: "Sound Design", type: .instrument)
        track.studioAnalogEnabled = true
        track.studioAnalogPatch = saved.patch
        track.studioAnalogPresetID = saved.id
        let restored = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(restored.studioAnalogPresetID, saved.id)
        XCTAssertEqual(restored.studioAnalogPatch, patch)

        try store.delete(saved)
        XCTAssertTrue(try store.loadUserPresets().presets.isEmpty)
        // Project still contains a complete copy of the old sound.
        XCTAssertEqual(restored.studioAnalogPatch?.value(for: .filterCutoff), 1234)
        XCTAssertThrowsError(try store.delete(StudioAnalogFactoryLibrary.presets[0]))
    }

    func testMalformedFilesAreSkippedWithoutHidingValidPresets() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-analog-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = StudioAnalogPresetStore(directory: temp)
        let kept = try store.save(name: "Kept", summary: "", category: .bass,
                                  patch: StudioAnalogPatch())
        let corrupt = temp.appendingPathComponent("broken.studioanalog.json")
        try Data("{ invalid json }".utf8).write(to: corrupt)
        let result = try store.loadUserPresets()
        XCTAssertEqual(result.presets, [kept])
        XCTAssertEqual(result.skippedFiles, [corrupt.lastPathComponent])

        var invalid = StudioAnalogPatch()
        invalid.values["9999"] = 0.4
        XCTAssertThrowsError(try store.save(name: "Invalid", summary: "",
                                             category: .lead, patch: invalid))
        XCTAssertThrowsError(try store.save(name: "  ", summary: "",
                                             category: .lead, patch: .init()))
        XCTAssertThrowsError(try store.save(name: String(repeating: "x", count: 81),
                                             summary: "", category: .lead, patch: .init()))
    }

    func testLegacyProjectAndVersionedPresetCompatibility() throws {
        let legacy = Data(#"{"version":1,"values":{"6":1250}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioAnalogPatch.self, from: legacy)
        XCTAssertEqual(decoded.value(for: .filterCutoff), 1250)
        XCTAssertEqual(decoded.activeConnections, StudioAnalogConnection.factory)
        var future = StudioAnalogPreset(id: UUID().uuidString, origin: .user,
                                        name: "Future", summary: "", category: .texture,
                                        patch: decoded)
        future.patch.version = 999
        XCTAssertThrowsError(try future.validate())
    }
}
