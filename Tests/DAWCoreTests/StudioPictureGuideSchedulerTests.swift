import Foundation
import XCTest
@testable import DAWCore

final class StudioPictureGuideSchedulerTests: XCTestCase {
    func testGuideAudioBeginsOnCorrectMovieFrame() {
        let segment = StudioPictureGuideScheduler.segment(
            projectSeconds: 15.5, pictureStartSeconds: 12.0,
            fileSampleRate: 48_000, totalFrames: 480_000)
        XCTAssertEqual(segment?.startingFrame, 168_000)
        XCTAssertEqual(segment?.frameCount, 312_000)
    }

    func testGuideDoesNotPlayBeforePictureOrAfterAudioEnds() {
        XCTAssertNil(StudioPictureGuideScheduler.segment(
            projectSeconds: 2, pictureStartSeconds: 4,
            fileSampleRate: 44_100, totalFrames: 441_000))
        XCTAssertNil(StudioPictureGuideScheduler.segment(
            projectSeconds: 20, pictureStartSeconds: 4,
            fileSampleRate: 44_100, totalFrames: 441_000))
    }

    func testLoopReschedulingUsesFreshSourceFrame() {
        let first = StudioPictureGuideScheduler.segment(
            projectSeconds: 25, pictureStartSeconds: 5,
            fileSampleRate: 48_000, totalFrames: 2_400_000)
        let wrapped = StudioPictureGuideScheduler.segment(
            projectSeconds: 10, pictureStartSeconds: 5,
            fileSampleRate: 48_000, totalFrames: 2_400_000)
        XCTAssertEqual(first?.startingFrame, 960_000)
        XCTAssertEqual(wrapped?.startingFrame, 240_000)
    }

    func testSegmentBoundsLongRecordingsToMaxAVAudioFrameCount() {
        let segment = StudioPictureGuideScheduler.segment(
            projectSeconds: 0, pictureStartSeconds: 0,
            fileSampleRate: 48_000, totalFrames: 5_000_000_000)
        XCTAssertEqual(segment?.startingFrame, 0)
        XCTAssertEqual(segment?.frameCount, UInt32.max)
    }

    func testInvalidInputsNeverCreateRealtimePlaybackSegments() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(StudioPictureGuideScheduler.segment(
                projectSeconds: value, pictureStartSeconds: 0,
                fileSampleRate: 48_000, totalFrames: 480_000))
            XCTAssertNil(StudioPictureGuideScheduler.segment(
                projectSeconds: 5, pictureStartSeconds: 0,
                fileSampleRate: value, totalFrames: 480_000))
        }
        XCTAssertNil(StudioPictureGuideScheduler.segment(
            projectSeconds: 3, pictureStartSeconds: 0,
            fileSampleRate: 48_000, totalFrames: 0))
    }

    func testReferenceAudioDefaultsKeepExistingMovieProjectsCompatible() throws {
        let original = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/movie.mov"),
            durationSeconds: 60, frameRate: .fps24)
        XCTAssertFalse(original.referenceAudioEnabled)
        XCTAssertNil(original.referenceAudioVolume)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "referenceAudioVolume")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(
            StudioPictureProject.self, from: data).referenceAudioVolume)
    }
}
