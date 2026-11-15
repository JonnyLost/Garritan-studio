import Foundation
import XCTest
@testable import DAWCore

final class StudioPackageReplacementTests: XCTestCase {
    func testPromotionFailureRestoresPreviousPackage() throws {
        try checkFailure(rollbackFails: false)
    }
    func testFailedRollbackLeavesRecoverableBackup() throws {
        try checkFailure(rollbackFails: true)
    }
    private func checkFailure(rollbackFails: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("Session.dawproj")
        let staging = root.appendingPathComponent("staging")
        let backup = root.appendingPathComponent(".Session.dawproj.backup-test")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("last good version".utf8).write(to: destination.appendingPathComponent("state"))
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertThrowsError(try StudioPackageReplacement.promote(
            staging: staging, destination: destination, backup: backup
        ) { from, to in
            if from == staging || (rollbackFails && from == backup) {
                throw CocoaError(.fileWriteUnknown)
            }
            try fm.moveItem(at: from, to: to)
        })
        let survivor = rollbackFails ? backup : destination
        XCTAssertEqual(try Data(contentsOf: survivor.appendingPathComponent("state")),
                       Data("last good version".utf8))
    }

    func testSuccessfulSaveRetainsPreviousVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Session.dawproj")
        let manager = ProjectFileManager()
        try await manager.save(project: Project(name: "Earlier"), to: url)
        try await manager.save(project: Project(name: "Latest"), to: url)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".Session.dawproj.backup-") })
        let previous = try await manager.load(from: backup)
        let latest = try await manager.load(from: url)
        XCTAssertEqual(previous.name, "Earlier")
        XCTAssertEqual(latest.name, "Latest")
    }
}
