import Foundation
import XCTest
@testable import DAWCore

final class StudioPictureTimecodeTests: XCTestCase {
    func testSMPTERoundTripsAtSupportedRates() {
        for rate in StudioPictureFrameRate.allCases {
            for label in ["00:00:00:00", "01:00:00:00", "10:17:30:12", "23:59:59:00"] {
                guard let frame = StudioPictureTimecode.frameNumber(label, rate: rate) else {
                    XCTFail("Invalid test timecode for \(rate): \(label)")
                    continue
                }
                XCTAssertEqual(StudioPictureTimecode.string(frameNumber: frame, rate: rate),
                               rate.droppedLabelsPerMinute > 0
                                ? String(label.dropLast(3)) + ";" + String(label.suffix(2))
                                : label)
            }
        }
    }

    func test2997DropFrameMinuteAndHourBoundaries() {
        let rate = StudioPictureFrameRate.fps2997Drop
        XCTAssertNil(StudioPictureTimecode.frameNumber("00:01:00;00", rate: rate))
        XCTAssertNil(StudioPictureTimecode.frameNumber("00:01:00;01", rate: rate))
        XCTAssertNotNil(StudioPictureTimecode.frameNumber("00:10:00;00", rate: rate))
        XCTAssertEqual(StudioPictureTimecode.string(frameNumber: 17_982, rate: rate), "00:10:00;00")
        XCTAssertEqual(StudioPictureTimecode.string(frameNumber: 107_892, rate: rate), "01:00:00;00")
        XCTAssertEqual(StudioPictureTimecode.frameNumber("01:00:00;00", rate: rate), 107_892)
    }

    func test5994DropFrameTenMinuteBoundary() {
        let rate = StudioPictureFrameRate.fps5994Drop
        for number in 0..<4 {
            XCTAssertNil(StudioPictureTimecode.frameNumber(
                String(format: "00:01:00;%02d", number), rate: rate))
        }
        XCTAssertEqual(StudioPictureTimecode.string(frameNumber: 35_964, rate: rate), "00:10:00;00")
    }

    func testFrameBasedHitPointsStayAtSameSMPTEAfterProjectOffsetChanges() {
        let url = URL(fileURLWithPath: "/tmp/Reference.mov")
        var picture = StudioPictureProject(
            url: url, durationSeconds: 120, frameRate: .fps24,
            hitPoints: [StudioPictureHitPoint(name: "Door shuts", frame: 240)])
        XCTAssertEqual(picture.timecode(atMovieFrame: 240), "01:00:10:00")
        picture.timelineStartSeconds = 15
        XCTAssertEqual(picture.timecode(atMovieFrame: 240), "01:00:10:00")
        XCTAssertEqual(picture.projectSeconds(atMovieFrame: 240), 25, accuracy: 0.000_001)
    }

    func testOptionalPicturePreservesLegacyProjectEncoding() throws {
        let project = Project(name: "Legacy")
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        XCTAssertNil(decoded.studioPicture)
    }

    func testTempoSuggestionBetweenTwoHitPoints() {
        let picture = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            durationSeconds: 30, frameRate: .fps24)
        let first = StudioPictureHitPoint(name: "A", frame: 0)
        let second = StudioPictureHitPoint(name: "B", frame: 96)
        XCTAssertEqual(picture.suggestedTempo(from: first, to: second), 120)
    }
}
