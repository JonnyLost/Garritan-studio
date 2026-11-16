import Foundation
import XCTest
@testable import DAWCore

final class StudioPictureCueNavigationTests: XCTestCase {
    private func project(rate: StudioPictureFrameRate = .fps24) -> StudioPictureProject {
        var p = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/scene.mov"),
            durationSeconds: 120, frameRate: rate,
            timelineStartSeconds: 15)
        p.hitPoints = [
            StudioPictureHitPoint(name: "Door", frame: 240,
                                  kind: .action, notes: "Quiet strings"),
            StudioPictureHitPoint(name: "Cut A", frame: 48,
                                  kind: .cut, notes: "Scene 4"),
            StudioPictureHitPoint(name: "Explosion", frame: 480,
                                  kind: .impact, notes: "Brass hit")
        ]
        return p
    }

    func testFilterByNameNotesTimecodeAndKind() {
        let p = project()
        XCTAssertEqual(StudioPictureCueNavigation.matching(p, query: "").map(\.name),
                       ["Cut A", "Door", "Explosion"])
        XCTAssertEqual(StudioPictureCueNavigation.matching(p, query: "strings").map(\.name),
                       ["Door"])
        XCTAssertEqual(StudioPictureCueNavigation.matching(p, query: "01:00:02:00").map(\.name),
                       ["Cut A"])
        XCTAssertEqual(StudioPictureCueNavigation.matching(
            p, query: "", kind: .impact).map(\.name), ["Explosion"])
        XCTAssertTrue(StudioPictureCueNavigation.matching(
            p, query: "Door", kind: .cut).isEmpty)
    }

    func testFilteredAdjacentCueNavigationUsesMovieFrames() {
        let p = project()
        XCTAssertEqual(StudioPictureCueNavigation.adjacent(
            p, currentFrame: 100, direction: 1)?.name, "Door")
        XCTAssertEqual(StudioPictureCueNavigation.adjacent(
            p, currentFrame: 240, direction: -1)?.name, "Cut A")
        XCTAssertNil(StudioPictureCueNavigation.adjacent(
            p, currentFrame: 480, direction: 1))
        XCTAssertEqual(StudioPictureCueNavigation.adjacent(
            p, currentFrame: 0, direction: 1, kind: .impact)?.name,
            "Explosion")
    }

    func testSMPTEGoToLocatesFrameAndRejectsOutOfRange() {
        let p = project()
        XCTAssertEqual(StudioPictureCueNavigation.frame(
            forEnteredTimecode: " 01:00:10:00 ", picture: p), 240)
        XCTAssertNil(StudioPictureCueNavigation.frame(
            forEnteredTimecode: "01:10:00:00", picture: p))
        XCTAssertNil(StudioPictureCueNavigation.frame(
            forEnteredTimecode: "nonsense", picture: p))
    }

    func testDropFrameLocatorRejectsNonexistentLabels() {
        let p = project(rate: .fps2997Drop)
        XCTAssertNil(StudioPictureCueNavigation.frame(
            forEnteredTimecode: "01:01:00;00", picture: p))
        XCTAssertEqual(StudioPictureCueNavigation.frame(
            forEnteredTimecode: "01:00:00;10", picture: p), 10)
    }
}
