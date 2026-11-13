import Foundation
import XCTest
@testable import DAWCore

final class StudioSessionRevisionTests: XCTestCase {
    func testSaveFinishingAfterAnotherEditDoesNotMarkDocumentClean() {
        var session = StudioSessionRevision()
        session.markEdited()
        let firstSave = session.saveTicket()
        session.markEdited()
        XCTAssertFalse(session.markSaved(firstSave))
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.savedRevision, 1)
        XCTAssertEqual(session.editRevision, 2)
        XCTAssertTrue(session.markSaved(session.saveTicket()))
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testOldSaveReceiptCannotClearOrModifyNewDocument() {
        var session = StudioSessionRevision()
        session.markEdited()
        let oldSave = session.saveTicket()
        session.replaceSession()
        session.markEdited()
        XCTAssertFalse(session.markSaved(oldSave))
        XCTAssertEqual(session.savedRevision, 0)
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    func testSaveReceiptsAreMonotonic() {
        var session = StudioSessionRevision()
        session.markEdited()
        let older = session.saveTicket()
        session.markEdited()
        let newer = session.saveTicket()
        XCTAssertTrue(session.markSaved(newer))
        XCTAssertTrue(session.markSaved(older))
        XCTAssertEqual(session.savedRevision, 2)
    }

    func testSaveURLNormalizationMatchesPersistenceContract() {
        let root = URL(fileURLWithPath: "/tmp/StudioSession")
        XCTAssertEqual(ProjectFileManager.normalizedProjectURL(
            root.appendingPathComponent("Sketch")
        ).lastPathComponent, "Sketch.dawproj")
        XCTAssertEqual(ProjectFileManager.normalizedProjectURL(
            root.appendingPathComponent("Sketch.dawproj")
        ).lastPathComponent, "Sketch.dawproj")
    }
}

final class StudioProjectMetadataCompatibilityTests: XCTestCase {
    func testLegacyProjectMetadataCanBeReadWithoutEnvelope() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioMetadata-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.json")
        let project = Project(name: "Historic project")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: url)
        let metadata = try await ProjectFileManager().loadMetadata(from: url)
        XCTAssertEqual(metadata.name, project.name)
        XCTAssertEqual(metadata.id, project.id)
    }

    func testFutureFormatIsNotSilentlyDowngraded() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioFuture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("NextVersion.dawproj")
        let manager = ProjectFileManager()
        try await manager.save(project: Project(name: "Future"), to: url)
        let jsonURL = url.appendingPathComponent("project.json")
        let data = try Data(contentsOf: jsonURL)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        envelope["version"] = Project.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: envelope).write(to: jsonURL)
        do {
            _ = try await manager.load(from: url)
            XCTFail("Newer document versions must not load as legacy content")
        } catch let error as PersistenceError {
            guard case .invalidFormat = error else {
                return XCTFail("Expected explicit unsupported-format error")
            }
        }
    }
}
