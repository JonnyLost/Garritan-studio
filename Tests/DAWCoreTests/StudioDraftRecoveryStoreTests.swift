import Foundation
import XCTest
@testable import DAWCore

final class StudioDraftRecoveryStoreTests: XCTestCase {
    private func fixture() throws -> (URL, StudioDraftRecoveryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StudioDrafts-\(UUID())", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, StudioDraftRecoveryStore(directory: root))
    }

    func testUnsavedDraftRoundTripAndExplicitDiscard() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let original = Project(name: "Unfinished orchestration")
        let stored = try await store.store(project: original, sessionID: sessionID)
        XCTAssertTrue(stored)

        let drafts = await store.availableDrafts()
        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.id, sessionID)
        XCTAssertEqual(draft.projectName, original.name)
        let reopened = try await store.load(draft)
        XCTAssertEqual(reopened.id, original.id)
        XCTAssertEqual(reopened.name, original.name)

        try await store.discard(sessionID: sessionID)
        let remaining = await store.availableDrafts()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnrelatedDraftsRemainIntactAfterDiscard() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let discarded = UUID(), preserved = UUID()
        try await store.store(project: Project(name: "First"), sessionID: discarded)
        try await store.store(project: Project(name: "Second"), sessionID: preserved)
        try await store.discard(sessionID: discarded)
        let drafts = await store.availableDrafts()
        XCTAssertEqual(drafts.map(\.id), [preserved])
    }

    func testDamagedDraftIsNotAutomaticallyErased() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("\(UUID().uuidString).dawproj")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: file.appendingPathComponent("project.json"))
        let remaining = await store.availableDrafts()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRecoveryRetainsPackagedAudioAfterExternalSourceRemoved() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("take.wav")
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        try audio.write(to: recording)
        var project = Project(name: "Recording")
        project.audioFiles.append(AudioFileReference(
            originalPath: recording.path, relativePath: "",
            sampleRate: 44100, channelCount: 2,
            lengthInSamples: 4, bitDepth: 24
        ))
        let id = UUID()
        try await store.store(project: project, sessionID: id)
        try FileManager.default.removeItem(at: recording)

        let drafts = await store.availableDrafts()
        let draft = try XCTUnwrap(drafts.first)
        let restored = try await store.load(draft)
        let location = try XCTUnwrap(restored.audioFiles.first?.originalPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: location)), audio)
    }
}
