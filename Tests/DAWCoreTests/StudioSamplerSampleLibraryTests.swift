import XCTest
import Foundation
@testable import DAWCore

/// No private user library is modified by these tests. Explicit temporary
/// roots simulate project migration, missing recordings and failed imports.
final class StudioSamplerSampleLibraryTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSamplerLibraryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        return folder
    }

    func testManagedReferenceRecoversAfterUserHomeMoves() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let name = "\(UUID().uuidString)-SoloViolin_C4_rr1.wav"
        let stored = root.appendingPathComponent(name)
        try Data([1, 2, 3, 4]).write(to: stored)

        // Legacy patch only contained an absolute path; the new resolver
        // identifies its imported UUID under the old GarritanStudio folder.
        let oldPath = "/Users/oldaccount/Library/Application Support/GarritanStudio/SamplerSamples/\(name)"
        var zone = StudioSamplerZone(sampleURL: URL(fileURLWithPath: oldPath))
        XCTAssertNil(zone.managedFileName)
        zone.roundRobinIndex = 1
        zone.trimStartFrame = 2
        zone.trimEndFrame = 100
        zone.articulationID = 0
        var patch = StudioSamplerPatch(zones: [zone])
        XCTAssertTrue(patch.isValid)

        // Retain the new managed reference through JSON serialization.
        let recovered = try StudioSamplerSampleLibrary.resolve(patch, in: root)
        XCTAssertEqual(recovered.zones[0].filePath, stored.path)
        XCTAssertEqual(recovered.zones[0].managedFileName, name)
        XCTAssertEqual(recovered.zones[0].roundRobinIndex, 1)
        XCTAssertEqual(recovered.zones[0].trimStartFrame, 2)
        XCTAssertEqual(recovered.zones[0].trimEndFrame, 100)

        patch = try JSONDecoder().decode(
            StudioSamplerPatch.self,
            from: JSONEncoder().encode(recovered)
        )
        XCTAssertEqual(patch.zones[0].managedFileName, name)
        XCTAssertEqual(try StudioSamplerSampleLibrary.resolve(patch, in: root),
                       recovered)
    }

    func testMissingManagedFileFailsWithoutSubstitutingUnrelatedFiles() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "\(UUID().uuidString)-original.wav"
        let original = URL(fileURLWithPath: "/Users/previous/\(name)")
        var zone = StudioSamplerZone(sampleURL: original)
        zone.managedFileName = name
        let patch = StudioSamplerPatch(zones: [zone])
        XCTAssertTrue(patch.isValid)

        // An unrelated same-named file must never silently replace the
        // user's actual missing library sample.
        let otherRoot = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try Data([9, 9, 9]).write(to: otherRoot.appendingPathComponent(name))
        XCTAssertThrowsError(try StudioSamplerSampleLibrary.resolve(patch, in: root)) {
            guard case StudioSamplerSampleLibrary.LibraryError.missingSample(let actual) = $0
            else { return XCTFail("Expected missingSample, got \($0)") }
            XCTAssertEqual(actual, name)
        }
    }

    func testUntrustedManagedReferenceCannotEscapeLibraryRoot() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["../other.wav", "/tmp/other.wav", "subdirectory/other.wav",
                     "..", ".", "folder\\other.wav"] {
            XCTAssertFalse(StudioSamplerSampleLibrary.validManagedFileName(name))
            var zone = StudioSamplerZone(sampleURL: URL(fileURLWithPath: "/tmp/old.wav"))
            zone.managedFileName = name
            XCTAssertFalse(zone.isValid)
            XCTAssertThrowsError(
                try StudioSamplerSampleLibrary.resolve(
                    StudioSamplerPatch(zones: [zone]), in: root
                )
            )
        }
    }

    func testRelinkImportsPrivateCopyAndBatchFailureRollsBack() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let original = sourceDir.appendingPathComponent("cello_C3_rr2.wav")
        let originalData = Data([0, 1, 2, 3, 4, 5])
        try originalData.write(to: original)
        let invalid = sourceDir.appendingPathComponent("missing.wav")

        XCTAssertThrowsError(
            try StudioSamplerSampleLibrary.importFiles([original, invalid], into: root)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).count, 0)
        XCTAssertEqual(try Data(contentsOf: original), originalData)

        let imported = try XCTUnwrap(
            StudioSamplerSampleLibrary.importFiles([original], into: root).first
        )
        XCTAssertNotEqual(imported, original)
        XCTAssertEqual(try Data(contentsOf: imported), originalData)
        XCTAssertNotNil(StudioSamplerSampleLibrary.managedName(for: imported, in: root))
        XCTAssertEqual(StudioSamplerSampleLibrary.managedName(for: original, in: root),
                       nil)
    }

    func testManagedSymlinkCannotEscapeThePrivateSampleFolder() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let name = "\(UUID().uuidString)-linked.wav"
        let actual = outside.appendingPathComponent("outside.wav")
        try Data([3, 2, 1]).write(to: actual)
        let linked = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)

        var zone = StudioSamplerZone(
            sampleURL: URL(fileURLWithPath: "/Users/old/GarritanStudio/SamplerSamples/\(name)")
        )
        zone.managedFileName = name
        XCTAssertThrowsError(
            try StudioSamplerSampleLibrary.resolve(
                StudioSamplerPatch(zones: [zone]), in: root
            )
        )
        XCTAssertThrowsError(
            try StudioSamplerSampleLibrary.importFiles([linked], into: root)
        )
        XCTAssertEqual(try Data(contentsOf: actual), Data([3, 2, 1]))
    }

    func testReopeningLegacyProjectPreservesUnresolvedSampleMapping() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("LegacyProject.json")
        var project = Project(name: "Missing sample recovery")
        var track = Track(name: "Native Strings", type: .instrument)
        let patch = StudioSamplerPatch(
            sampleURL: URL(fileURLWithPath: "/a/removed/drive/violin.wav")
        )
        track.studioSamplerPatch = patch
        project.addTrack(track)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: path)

        // A missing sample must not cause the user's entire composition to
        // disappear. Only instrument attachment may fail until relinked.
        let manager = ProjectFileManager()
        let reopened = try await manager.load(from: path)
        XCTAssertEqual(reopened.name, project.name)
        XCTAssertEqual(reopened.tracks.count, 1)
        XCTAssertEqual(reopened.tracks[0].studioSamplerPatch, patch)
    }

    func testOrdinaryExternalReferenceRemainsSupported() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = root.appendingPathComponent("external.wav")
        try Data([1, 2, 3]).write(to: sample)
        let zone = StudioSamplerZone(sampleURL: sample)
        let patch = StudioSamplerPatch(zones: [zone])
        let restored = try StudioSamplerSampleLibrary.resolve(
            patch, in: root.appendingPathComponent("managed", isDirectory: true)
        )
        XCTAssertEqual(restored, patch)
        XCTAssertNil(restored.zones[0].managedFileName)
    }
}
