import Foundation
import XCTest
@testable import DAWCore

final class StudioPictureCueVisualTests: XCTestCase {
    private func picture(rate: StudioPictureFrameRate = .fps24) -> StudioPictureProject {
        var p = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/scoring.mov"),
            durationSeconds: 30, frameRate: rate,
            timelineStartSeconds: 12)
        p.hitPoints = [
            StudioPictureHitPoint(name: "First impact", frame: 120, kind: .impact),
            StudioPictureHitPoint(name: "Second impact", frame: 240, kind: .impact)
        ]
        return p
    }

    func testStreamersFollowPictureOffsetAndLandOnFrame() throws {
        let p = picture()
        XCTAssertNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 11))
        let first = try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 14))
        XCTAssertEqual(first.name, "First impact")
        XCTAssertEqual(first.progress, 0, accuracy: 0.001)
        XCTAssertFalse(first.isPunch)
        let middle = try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 15.5))
        XCTAssertEqual(middle.progress, 0.5, accuracy: 0.001)
        let punch = try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 17))
        XCTAssertTrue(punch.isPunch)
        XCTAssertEqual(punch.progress, 1, accuracy: 0.001)
    }

    func testPunchIsOnlySinglePictureFrame() throws {
        let p = picture()
        XCTAssertTrue(try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 17)).isPunch)
        XCTAssertNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 17 + 1.0 / 24))
    }

    func testVideoFrameRateDrivesFractionalRateTiming() throws {
        var p = picture(rate: .fps2997Drop)
        p.hitPoints = [StudioPictureHitPoint(name: "DF hit", frame: 300)]
        let target = p.projectSeconds(atMovieFrame: 300)
        let punch = try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: target))
        XCTAssertTrue(punch.isPunch)
        XCTAssertEqual(punch.name, "DF hit")
    }

    func testDisableModesAndLegacyDefaults() throws {
        var p = picture()
        p.showScoringStreamers = false
        XCTAssertNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 15))
        XCTAssertTrue(try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 17)).isPunch)
        p.showScoringPunches = false
        XCTAssertNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 17))

        let data = try JSONEncoder().encode(p)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "showScoringStreamers")
        json.removeValue(forKey: "showScoringPunches")
        json.removeValue(forKey: "streamerLeadSeconds")
        let restored = try JSONDecoder().decode(StudioPictureProject.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.showScoringStreamers)
        XCTAssertNil(restored.showScoringPunches)
        XCTAssertNil(restored.streamerLeadSeconds)
        XCTAssertNotNil(StudioPictureCueVisualPlanner.visual(
            picture: restored, projectSeconds: 15))
    }

    func testMalformedCueLeadIsBoundedWithoutOverflow() {
        var p = picture()
        p.streamerLeadSeconds = .infinity
        XCTAssertNotNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 15))
        p.streamerLeadSeconds = -1
        XCTAssertNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 15))
        XCTAssertNil(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: .nan))
    }

    func testNearestUpcomingHitWins() throws {
        var p = picture()
        p.hitPoints.append(StudioPictureHitPoint(name: "Extra", frame: 121))
        let cue = try XCTUnwrap(StudioPictureCueVisualPlanner.visual(
            picture: p, projectSeconds: 12 + 121.5 / 24.0))
        XCTAssertEqual(cue.name, "Extra")
        XCTAssertTrue(cue.isPunch)
    }
}
