import Foundation
import XCTest
@testable import DAWCore

final class StudioPictureRevisionConformerTests: XCTestCase {
    private func picture(seconds: Double = 20,
                         rate: StudioPictureFrameRate = .fps24,
                         filename: String = "old.mov") -> StudioPictureProject {
        StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/" + filename),
            durationSeconds: seconds, frameRate: rate,
            timelineStartSeconds: 12,
            hitPoints: [
                StudioPictureHitPoint(name: "Opening", frame: 24, kind: .cut),
                StudioPictureHitPoint(name: "Door", frame: 144, kind: .action,
                                      notes: "Violins begin"),
                StudioPictureHitPoint(name: "Impact", frame: 288, kind: .impact,
                                      notes: "Brass and percussion")
            ])
    }

    func testInsertedFootageMovesOnlyLaterHitPoints() throws {
        let old = picture()
        let new = picture(seconds: 23, filename: "new.mov")
        // Insert two seconds after old frame 120. Anchor before insertion,
        // then one at the first matching frame after the inserted scene.
        let anchors = [
            StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0),
            StudioPictureRevisionAnchor(oldFrame: 120, newFrame: 168)
        ]
        let preview = try StudioPictureRevisionConformer.preview(
            old: old, replacement: new, anchors: anchors)
        XCTAssertEqual(preview.unresolvedCount, 0)
        XCTAssertEqual(preview.changes.map(\.proposedFrame), [24, 192, 336])
        XCTAssertEqual(preview.movedCount, 2)

        let result = try StudioPictureRevisionConformer.conform(
            old: old, replacement: new, preview: preview)
        XCTAssertEqual(result.hitPoints.map(\.frame), [24, 192, 336])
        XCTAssertEqual(result.hitPoints.map(\.id), old.hitPoints.map(\.id))
        XCTAssertEqual(result.hitPoints.map(\.notes), old.hitPoints.map(\.notes))
        XCTAssertEqual(result.timelineStartSeconds, old.timelineStartSeconds)
        XCTAssertEqual(result.filename, "new.mov")
        XCTAssertEqual(old.hitPoints.map(\.frame), [24, 144, 288])
    }

    func testDeletedFootageCanMapLaterCueBackWithoutStretching() throws {
        let old = picture()
        let new = picture(seconds: 18, filename: "shorter.mov")
        let preview = try StudioPictureRevisionConformer.preview(
            old: old, replacement: new,
            anchors: [
                StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0),
                StudioPictureRevisionAnchor(oldFrame: 120, newFrame: 72)
            ])
        let result = try StudioPictureRevisionConformer.conform(
            old: old, replacement: new, preview: preview)
        XCTAssertEqual(result.hitPoints.map(\.frame), [24, 96, 240])
    }

    func testOutOfBoundsCuesDoNotGetSilentlyDropped() throws {
        let old = picture()
        let short = picture(seconds: 4, filename: "short.mov")
        let preview = try StudioPictureRevisionConformer.preview(
            old: old, replacement: short,
            anchors: [StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0)])
        XCTAssertEqual(preview.unresolvedCount, 2)
        XCTAssertEqual(preview.changes.count, old.hitPoints.count)
        XCTAssertNil(preview.changes.last?.proposedFrame)
        XCTAssertThrowsError(try StudioPictureRevisionConformer.conform(
            old: old, replacement: short, preview: preview))
    }

    func testInvalidAndNonMonotonicAnchorsAreRejected() {
        let old = picture()
        let new = picture(filename: "new.mov")
        let bad: [[StudioPictureRevisionAnchor]] = [
            [],
            [StudioPictureRevisionAnchor(oldFrame: -1, newFrame: 0)],
            [StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 999_999)],
            [
                StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 40),
                StudioPictureRevisionAnchor(oldFrame: 100, newFrame: 20)
            ],
            [
                StudioPictureRevisionAnchor(oldFrame: 30, newFrame: 30),
                StudioPictureRevisionAnchor(oldFrame: 30, newFrame: 60)
            ]
        ]
        for anchors in bad {
            XCTAssertThrowsError(try StudioPictureRevisionConformer.preview(
                old: old, replacement: new, anchors: anchors))
        }
    }

    func testFractionalRateConversionPreservesElapsedTime() throws {
        let old = picture(rate: .fps24)
        let new = picture(seconds: 20, rate: .fps2997Drop,
                          filename: "ntsc.mov")
        let anchors = [StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0)]
        let preview = try StudioPictureRevisionConformer.preview(
            old: old, replacement: new, anchors: anchors)
        let result = try StudioPictureRevisionConformer.conform(
            old: old, replacement: new, preview: preview)
        XCTAssertEqual(result.hitPoints[0].frame, 30)
        XCTAssertEqual(result.hitPoints[1].frame, 180)
        XCTAssertEqual(result.hitPoints[2].frame, 360)
        XCTAssertTrue(result.timecode(atMovieFrame: 0).contains(";"))
    }

    func testStalePreviewCannotApplyAfterOriginalCueChanges() throws {
        let old = picture()
        let new = picture(seconds: 25, filename: "v2.mov")
        let anchors = [StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0)]
        let preview = try StudioPictureRevisionConformer.preview(
            old: old, replacement: new, anchors: anchors)
        var revisedOriginal = old
        revisedOriginal.hitPoints[0].frame += 10
        XCTAssertThrowsError(try StudioPictureRevisionConformer.conform(
            old: revisedOriginal, replacement: new, preview: preview))
    }

    func testDoesNotRewriteSavedTimecodeOrMonitorChoices() throws {
        var old = picture()
        old.referenceAudioEnabled = true
        old.referenceAudioVolume = 0.4
        old.showScoringStreamers = false
        old.showScoringPunches = true
        old.streamerLeadSeconds = 5
        let replacement = picture(filename: "director-cut.mov")
        let preview = try StudioPictureRevisionConformer.preview(
            old: old, replacement: replacement,
            anchors: [StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0)])
        let conformed = try StudioPictureRevisionConformer.conform(
            old: old, replacement: replacement, preview: preview)
        XCTAssertTrue(conformed.referenceAudioEnabled)
        XCTAssertEqual(conformed.referenceAudioVolume, 0.4)
        XCTAssertEqual(conformed.showScoringStreamers, false)
        XCTAssertEqual(conformed.showScoringPunches, true)
        XCTAssertEqual(conformed.streamerLeadSeconds, 5)
        XCTAssertEqual(conformed.timecode(atMovieFrame: 0),
                       old.timecode(atMovieFrame: 0))
    }
}
