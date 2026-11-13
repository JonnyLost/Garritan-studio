import Foundation
import XCTest
@testable import DAWCore

@MainActor
final class StudioAutosaveManagerTests: XCTestCase {
    func testAutosaveStoresSnapshotAndReportsItsRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioAuto-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = AutosaveManager()
        let url = directory.appendingPathComponent("Sketch.dawproj")
        var session = StudioSessionRevision()
        session.markEdited()
        let ticket = session.saveTicket()
        var completed: StudioSessionSaveTicket?
        manager.configure(
            snapshotProvider: {
                StudioAutosaveSnapshot(project: Project(name: "Autosaved"), ticket: ticket)
            },
            onSaved: { _, savedTicket in completed = savedTicket }
        )
        manager.startAutosave(for: url)
        manager.markUnsavedChanges()
        await manager.saveIfNeeded()

        XCTAssertEqual(completed, ticket)
        XCTAssertFalse(manager.hasUnsavedChanges)
        let project = try await ProjectFileManager().load(from: url)
        XCTAssertEqual(project.name, "Autosaved")
        manager.stopAutosave()
    }

    func testChangeDuringSnapshotCaptureRemainsUnsaved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioAutoLate-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = AutosaveManager()
        let url = directory.appendingPathComponent("Sketch.dawproj")
        var revision = StudioSessionRevision()
        revision.markEdited()
        let ticket = revision.saveTicket()
        manager.configure(
            snapshotProvider: {
                try? await Task.sleep(nanoseconds: 40_000_000)
                return StudioAutosaveSnapshot(
                    project: Project(name: "First edit"), ticket: ticket
                )
            },
            onSaved: { _, _ in }
        )
        manager.startAutosave(for: url)
        manager.markUnsavedChanges()
        let task = Task { await manager.saveIfNeeded() }
        try await Task.sleep(nanoseconds: 10_000_000)
        manager.markUnsavedChanges()
        await task.value

        XCTAssertTrue(manager.hasUnsavedChanges)
        manager.stopAutosave()
    }

    func testStoppedSessionDoesNotWriteAfterSnapshotDelay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioAutoSwitch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = AutosaveManager()
        let url = directory.appendingPathComponent("OldSession.dawproj")
        var revision = StudioSessionRevision()
        revision.markEdited()
        let ticket = revision.saveTicket()
        manager.configure(
            snapshotProvider: {
                try? await Task.sleep(nanoseconds: 40_000_000)
                return StudioAutosaveSnapshot(
                    project: Project(name: "Old"), ticket: ticket
                )
            },
            onSaved: { _, _ in XCTFail("Old session must not emit save receipt") }
        )
        manager.startAutosave(for: url)
        manager.markUnsavedChanges()
        let task = Task { await manager.saveIfNeeded() }
        try await Task.sleep(nanoseconds: 10_000_000)
        manager.stopAutosave()
        await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
