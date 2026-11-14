import XCTest
import Foundation
@testable import DAWCore

final class StudioSynthUserPresetLibraryTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSynthPresets-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    func testSixEnginesAndHybridRoundTripThroughDisk() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for engine in StudioSynthEngine.allCases {
            let patch = StudioSynthPatch.individual(engine)
            let saved = try StudioSynthUserPresetLibrary.save(
                name: "My \(engine.title)", patch: patch, in: folder)
            let url = folder.appendingPathComponent(
                saved.id.uuidString).appendingPathExtension("studiosynth")
            let loaded = try StudioSynthUserPresetLibrary.load(from: url)
            XCTAssertEqual(loaded.name, saved.name)
            XCTAssertEqual(loaded.patch, patch)
            XCTAssertTrue(loaded.patch.validate())
        }
        let hybrid = StudioSynthPatch()
        let saved = try StudioSynthUserPresetLibrary.save(
            name: "My Hybrid", patch: hybrid, in: folder)
        XCTAssertEqual(try StudioSynthUserPresetLibrary.list(in: folder).count, 7)
        try StudioSynthUserPresetLibrary.delete(saved, in: folder)
        XCTAssertEqual(try StudioSynthUserPresetLibrary.list(in: folder).count, 6)
    }

    func testDuplicateNamesAndInvalidPatchesAreRejected() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let patch = StudioSynthPatch.individual(.analog)
        _ = try StudioSynthUserPresetLibrary.save(
            name: "Lead", patch: patch, in: folder)
        XCTAssertThrowsError(try StudioSynthUserPresetLibrary.save(
            name: "lead", patch: patch, in: folder))
        XCTAssertThrowsError(try StudioSynthUserPresetLibrary.save(
            name: "  ", patch: patch, in: folder))
        var invalid = patch
        invalid.layers[0].gain = .nan
        XCTAssertThrowsError(try StudioSynthUserPresetLibrary.save(
            name: "Broken", patch: invalid, in: folder))
    }

    func testCorruptPresetDoesNotHideValidPresets() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try StudioSynthUserPresetLibrary.save(
            name: "Working", patch: .individual(.fm), in: folder)
        try Data("not-json".utf8).write(
            to: folder.appendingPathComponent("broken.studiosynth"))
        let listed = try StudioSynthUserPresetLibrary.list(in: folder)
        XCTAssertEqual(listed.map(\.name), ["Working"])
    }
}
