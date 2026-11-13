import Foundation
import XCTest
@testable import DAWCore

final class StudioInterruptedSaveRecoveryTests: XCTestCase {
    func testInterruptedSaveRecoversCompleteBackupNotPartialStaging() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioRecovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        try await manager.save(project: Project(name: "Saved"), to: url)

        let backup = folder.appendingPathComponent(".Orchestra.dawproj.backup-\(UUID())")
        try FileManager.default.moveItem(at: url, to: backup)
        let staging = folder.appendingPathComponent(".Orchestra.dawproj.staging-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("project.json"))

        let opened = try await manager.load(from: url)
        XCTAssertEqual(opened.name, "Saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testInvalidBackupIsNeverPromoted() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioInvalidBackup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Orchestra.dawproj")
        let backup = folder.appendingPathComponent(".Orchestra.dawproj.backup-\(UUID())")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: backup.appendingPathComponent("project.json"))
        do {
            _ = try await ProjectFileManager().load(from: url)
            XCTFail("An incomplete backup must not become an openable project")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    func testExistingPackageAlwaysWinsOverBackup() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioExistingBackup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        try await manager.save(project: Project(name: "Old"), to: url)
        let backup = folder.appendingPathComponent(".Orchestra.dawproj.backup-\(UUID())")
        try FileManager.default.moveItem(at: url, to: backup)
        try await manager.save(project: Project(name: "New"), to: url)
        let opened = try await manager.load(from: url)
        XCTAssertEqual(opened.name, "New")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
}
