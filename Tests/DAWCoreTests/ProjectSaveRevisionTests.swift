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

    func testSessionResetStartsNewCleanRevisionHistory() {
        var revision = ProjectSaveRevision()
        revision.markChanged()
        XCTAssertTrue(revision.hasUnsavedChanges)

        // AppState checks its independent session UUID before acknowledging
        // any asynchronous save from the preceding project.
        revision.resetForNewSession()
        XCTAssertFalse(revision.hasUnsavedChanges)
        XCTAssertEqual(revision.current, 0)
        XCTAssertEqual(revision.saved, 0)
        revision.markChanged()
        XCTAssertTrue(revision.hasUnsavedChanges)
    }
}
