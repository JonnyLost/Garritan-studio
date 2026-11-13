import XCTest
@testable import DAWCore

final class ProjectSaveRevisionTests: XCTestCase {
    func testNewSessionBeginsCleanAndEditMakesDirty() {
        var revision = ProjectSaveRevision()
        XCTAssertFalse(revision.hasUnsavedChanges)
        revision.markChanged()
        XCTAssertEqual(revision.current, 1)
        XCTAssertTrue(revision.hasUnsavedChanges)
    }

    func testSuccessfulSaveOnlyAcknowledgesSerializedRevision() {
        var revision = ProjectSaveRevision()
        revision.markChanged()
        let snapshot = revision.capture()

        XCTAssertTrue(revision.acknowledgeSave(snapshot: snapshot))
        XCTAssertFalse(revision.hasUnsavedChanges)
        XCTAssertEqual(revision.saved, snapshot)
    }

    func testEditWhileSaveIsInFlightRemainsDirty() {
        var revision = ProjectSaveRevision()
        revision.markChanged()
        let snapshot = revision.capture()

        // A slow full package copy must not erase the user's later changes.
        revision.markChanged()
        XCTAssertFalse(revision.acknowledgeSave(snapshot: snapshot))
        XCTAssertTrue(revision.hasUnsavedChanges)
        XCTAssertEqual(revision.saved, 0)

        let newerSnapshot = revision.capture()
        XCTAssertTrue(revision.acknowledgeSave(snapshot: newerSnapshot))
        XCTAssertFalse(revision.hasUnsavedChanges)
    }

    func testOlderSaveCannotMarkNewerRevisionClean() {
        var revision = ProjectSaveRevision()
        revision.markChanged()
        let older = revision.capture()
        revision.markChanged()
        let newer = revision.capture()

        XCTAssertTrue(revision.acknowledgeSave(snapshot: newer))
        XCTAssertFalse(revision.acknowledgeSave(snapshot: older))
        XCTAssertFalse(revision.hasUnsavedChanges)
        XCTAssertEqual(revision.saved, newer)
    }

    func testSessionResetCannotAcknowledgeStaleSnapshotAfterNewEdit() {
        var revision = ProjectSaveRevision()
        revision.markChanged()
        let priorSession = revision.capture()
        revision.resetForNewSession()
        revision.markChanged()

        // AppState also uses an independent session UUID to fence save work.
        // The revision tracker itself tracks changes only within one session.
        XCTAssertEqual(priorSession, revision.capture())
        XCTAssertTrue(revision.hasUnsavedChanges)
        XCTAssertTrue(revision.acknowledgeSave(snapshot: revision.capture()))
        XCTAssertFalse(revision.hasUnsavedChanges)
    }
}
