import Foundation
import XCTest
@testable import DAWCore

/// Exercises Picture's document model through the safety branch's real package paths.
final class StudioAlpha1PictureRecoveryTests: XCTestCase {
    func testPictureSurvivesSavePreviousVersionAndInterruptedDraftRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Scoring.dawproj")
        let manager = ProjectFileManager()
        var project = Project(name: "Scoring")
        let first = StudioPictureProject(
            url: root.appendingPathComponent("external-movie.mov"),
            durationSeconds: 120, frameRate: .fps2997Drop,
            securityBookmark: Data([1, 2, 3]), timelineStartSeconds: 12,
            referenceAudioEnabled: true, referenceAudioVolume: 0.4,
            showScoringStreamers: true, showScoringPunches: false,
            streamerLeadSeconds: 4,
            hitPoints: [StudioPictureHitPoint(name: "Impact", frame: 240, notes: "Keep cue")])
        project.studioPicture = first
        try await manager.save(project: project, to: url)
        var revised = first
        revised.hitPoints[0].frame = 300
        revised.mediaRevisionID = UUID()
        project.studioPicture = revised
        try await manager.save(project: project, to: url)
        let reopened = try await manager.load(from: url)
        XCTAssertEqual(reopened.studioPicture, revised)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.hasPrefix(".Scoring.dawproj.backup-")
            })
        let previous = try await manager.load(from: backup)
        XCTAssertEqual(previous.studioPicture, first)

        let drafts = StudioDraftRecoveryStore(directory: root.appendingPathComponent("Drafts"))
        let sessionID = UUID()
        let stored = try await drafts.store(project: project, sessionID: sessionID)
        XCTAssertTrue(stored)
        let canonical = await drafts.draftURL(for: sessionID)
        let interruptedBackup = canonical.deletingLastPathComponent().appendingPathComponent(
            ".\(canonical.lastPathComponent).backup-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: canonical, to: interruptedBackup)
        let available = await drafts.availableDrafts()
        let draft = try XCTUnwrap(available.first)
        let recovered = try await drafts.load(draft)
        XCTAssertEqual(recovered.studioPicture, revised)
        XCTAssertTrue(FileManager.default.fileExists(atPath: interruptedBackup.path))
        // Missing external movie remains a relinkable reference, not a failed save.
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.filePath))
    }
}
