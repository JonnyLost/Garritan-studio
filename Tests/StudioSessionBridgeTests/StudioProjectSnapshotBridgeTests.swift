import Foundation
import XCTest
import DAWCore
@testable import DAWUI

@MainActor
final class StudioProjectSnapshotBridgeTests: XCTestCase {
    func testSnapshotsCanOnlyBeReadByTheirRegisteredProjectID() {
        let bridge = StudioProjectSnapshotBridge()
        let one = Project(name: "First")
        let other = Project(name: "Second")
        bridge.register(projectID: one.id, provider: { one })
        XCTAssertEqual(bridge.snapshot(for: one.id)?.id, one.id)
        XCTAssertNil(bridge.snapshot(for: other.id))
    }

    func testOldWindowCannotUnregisterNewWindow() {
        let bridge = StudioProjectSnapshotBridge()
        let older = Project(name: "Old")
        let newer = Project(name: "New")
        bridge.register(projectID: older.id, provider: { older })
        bridge.register(projectID: newer.id, provider: { newer })
        bridge.unregister(projectID: older.id)
        XCTAssertEqual(bridge.snapshot(for: newer.id)?.name, "New")
        bridge.unregister(projectID: newer.id)
        XCTAssertNil(bridge.snapshot(for: newer.id))
    }

    func testStaleProviderCannotReturnDifferentProject() {
        let bridge = StudioProjectSnapshotBridge()
        let oldProject = Project(name: "Old")
        let current = Project(name: "Current")
        bridge.register(projectID: current.id, provider: { oldProject })
        XCTAssertNil(bridge.snapshot(for: current.id))
    }
}
