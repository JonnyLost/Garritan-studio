import Foundation
import XCTest
@testable import DAWCore

/// Pin the established .dawproj and legacy JSON contract while app branding evolves.
@available(macOS 14.0, *)
final class StudioProjectFormatCompatibilityTests: XCTestCase {
    func testPackageEnvelopeAndRoundTripStayCompatible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioFormat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("ExistingSession.dawproj")
        let original = Project(name: "Existing orchestral session")
        let manager = ProjectFileManager()
        XCTAssertEqual(ProjectFileManager.projectExtension, "dawproj")

        try await manager.save(project: original, to: url)

        let manifestURL = url.appendingPathComponent("project.json")
        let data = try Data(contentsOf: manifestURL)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(envelope["version"] as? Int, Project.currentFormatVersion)
        XCTAssertNotNil(envelope["project"])
        XCTAssertNotNil(envelope["audioFileManifest"] as? [Any])
        XCTAssertNotNil(envelope["pluginStates"] as? [Any])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Audio Files").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Plugin States").path
        ))

        let reopened = try await manager.load(from: url)
        XCTAssertEqual(reopened.id, original.id)
        XCTAssertEqual(reopened.name, original.name)
    }

    func testLegacyUnwrappedJSONProjectStillOpens() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioLegacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = Project(name: "Legacy JSON")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent("older-session.json")
        try encoder.encode(original).write(to: url, options: .atomic)

        let reopened = try await ProjectFileManager().load(from: url)
        XCTAssertEqual(reopened.id, original.id)
        XCTAssertEqual(reopened.name, original.name)
    }
}
