import Foundation
import XCTest
@testable import DAWCore

final class StudioPictureScoringWorkflowTests: XCTestCase {
    private func movie(offset: Double = 0,
                       rate: StudioPictureFrameRate = .fps24,
                       seconds: Double = 60) -> StudioPictureProject {
        StudioPictureProject(url: URL(fileURLWithPath: "/tmp/scoring.mov"),
                             durationSeconds: seconds,
                             frameRate: rate,
                             timelineStartSeconds: offset)
    }

    func testPictureOffsetAndBeforeMovieDoesNotStartPlayback() {
        let picture = movie(offset: 12)
        let decision = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 5,
            movieSeconds: 0, isPlaying: true,
            secondsSinceCorrection: 1)
        XCTAssertFalse(decision.shouldPlay)
        XCTAssertTrue(decision.outsideMovieRange)
        XCTAssertEqual(decision.targetSeconds, 0, accuracy: 0.00001)

        let enter = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 13,
            movieSeconds: 0, isPlaying: true,
            secondsSinceCorrection: 2)
        XCTAssertTrue(enter.shouldPlay)
        XCTAssertTrue(enter.shouldSeek)
        XCTAssertEqual(enter.targetSeconds, 1, accuracy: 0.00001)
    }

    func testSmallPlaybackDriftDoesNotSeekOnEveryAudioCallback() {
        let picture = movie()
        let close = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 10,
            movieSeconds: 9.98, isPlaying: true,
            secondsSinceCorrection: 1)
        XCTAssertFalse(close.shouldSeek)

        let recentSeek = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 10,
            movieSeconds: 9, isPlaying: true,
            secondsSinceCorrection: 0.1)
        XCTAssertFalse(recentSeek.shouldSeek)

        let drifting = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 10,
            movieSeconds: 9.7, isPlaying: true,
            secondsSinceCorrection: 0.8)
        XCTAssertTrue(drifting.shouldSeek)
        XCTAssertEqual(drifting.targetSeconds, 10, accuracy: 0.00001)
    }

    func testLoopWrapSeeksImmediatelyAndBoundsEndOfMovie() {
        let picture = movie()
        XCTAssertTrue(StudioPictureSyncPlanner.isDiscontinuity(
            previousProjectSeconds: 30,
            previousUptime: 100,
            currentProjectSeconds: 12,
            uptime: 100.01))
        XCTAssertFalse(StudioPictureSyncPlanner.isDiscontinuity(
            previousProjectSeconds: 30,
            previousUptime: 100,
            currentProjectSeconds: 30.04,
            uptime: 100.05))

        let wrapped = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 12,
            movieSeconds: 30, isPlaying: true,
            secondsSinceCorrection: 0.01, discontinuity: true)
        XCTAssertTrue(wrapped.shouldSeek)
        XCTAssertTrue(wrapped.shouldPlay)

        let ended = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 100,
            movieSeconds: 59.9, isPlaying: true,
            secondsSinceCorrection: 1)
        XCTAssertFalse(ended.shouldPlay)
        XCTAssertTrue(ended.outsideMovieRange)
        XCTAssertLessThan(ended.targetSeconds, 60)
    }

    func testStoppedFrameScrubAndMovieDuration() {
        let picture = movie()
        let paused = StudioPictureSyncPlanner.plan(
            picture: picture, projectSeconds: 10.0 / 24,
            movieSeconds: 9.0 / 24, isPlaying: false,
            secondsSinceCorrection: 0)
        XCTAssertTrue(paused.shouldSeek)
        XCTAssertFalse(paused.shouldPlay)
        XCTAssertEqual(picture.movieFrame(atProjectSeconds: paused.targetSeconds), 10)
    }

    func testCueEditorAllowsFramePreciseSMPTEPositionAndMidnightWrap() {
        let picture = movie()
        XCTAssertEqual(picture.movieFrame(forTimecode: "01:00:00:10"), 10)
        XCTAssertNil(picture.movieFrame(forTimecode: "01:05:00:00"))
        XCTAssertNil(picture.movieFrame(forTimecode: "not-timecode"))

        let midnight = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/midnight.mov"),
            durationSeconds: 10, frameRate: .fps24,
            startTimecodeFrame: StudioPictureTimecode.frameNumber(
                "23:59:59:00", rate: .fps24))
        XCTAssertEqual(midnight.movieFrame(forTimecode: "00:00:00:00"), 24)
        XCTAssertEqual(midnight.timecode(atMovieFrame: 24), "00:00:00:00")
    }

    func testSafeCueSheetCSVIsOrderedAndPreservesNotes() {
        var picture = movie(rate: .fps2997Drop)
        picture.hitPoints = [
            StudioPictureHitPoint(name: "=evil", frame: 300,
                                  kind: .impact, notes: "Impact, then cut"),
            StudioPictureHitPoint(name: "Opening", frame: 0,
                                  kind: .cut, notes: "Quiet\nstrings")
        ]
        let csv = StudioPictureCueSheet.csv(for: picture)
        XCTAssertTrue(csv.hasPrefix("Cue,Type,SMPTE,Picture Frame,Project Seconds,Notes\r\n"))
        XCTAssertTrue(csv.contains("\"Opening\",\"Cut\",\"01:00:00;00\",0,0.000,\"Quiet\nstrings\""))
        XCTAssertTrue(csv.contains("\"'=evil\",\"Impact\""))
        XCTAssertTrue(csv.contains("\"Impact, then cut\""))
        let firstIndex = csv.range(of: "Opening")!.lowerBound
        let secondIndex = csv.range(of: "'=evil")!.lowerBound
        XCTAssertLessThan(firstIndex, secondIndex)
    }

    func testMovieRevisionMetadataSurvivesSaveAndLegacyPictureDecodes() throws {
        var picture = movie()
        picture.mediaRevisionID = UUID()
        let data = try JSONEncoder().encode(picture)
        XCTAssertEqual(try JSONDecoder().decode(StudioPictureProject.self, from: data), picture)

        // Simulates the first Studio Picture project before the optional token existed.
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "mediaRevisionID")
        json.removeValue(forKey: "showTimecodeOverlay")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(StudioPictureProject.self, from: legacy)
        XCTAssertNil(restored.mediaRevisionID)
        XCTAssertNil(restored.showTimecodeOverlay)
    }
}
