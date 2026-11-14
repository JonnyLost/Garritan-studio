import XCTest
import DAWCore
@testable import DAWUI

final class StudioMIDINoteEditingTests: XCTestCase {
    func testMovingChordRetainsRelativeTimingAndOtherEvents() {
        let a = MIDIEvent.note(at: 0.5, pitch: 60, duration: 0.75)
        let b = MIDIEvent.note(at: 0.75, pitch: 64, duration: 0.25)
        let cc = MIDIEvent.controlChange(at: 0.6, controller: 11, value: 80)
        let result = StudioMIDINoteEditing.moving([a, b, cc],
            selectedIDs: [a.id, b.id], beatDelta: -2,
            pitchDelta: 3, division: 0.25)
        XCTAssertEqual(result[0].beatPosition, 0)
        XCTAssertEqual(result[1].beatPosition, 0.25)
        XCTAssertEqual(result[2].beatPosition, cc.beatPosition)
        if case .note(let first) = result[0].type {
            XCTAssertEqual(first.pitch, 63)
        } else { XCTFail("Expected note") }
    }

    func testCopyPasteLeavesControllersAndOriginalIdentityUntouched() {
        let note = MIDIEvent.note(at: 1.5, pitch: 72, velocity: 93, duration: 1)
        let cc = MIDIEvent.controlChange(at: 1.5, controller: 1, value: 127)
        var events = [note, cc]
        let ids = StudioMIDINoteEditing.paste([note], into: &events, at: 4)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].id, note.id)
        XCTAssertEqual(events[1].id, cc.id)
        XCTAssertEqual(events[2].beatPosition, 4)
        XCTAssertNotEqual(events[2].id, note.id)
        if case .note(let data) = events[2].type {
            XCTAssertEqual(data.velocity, 93)
            XCTAssertEqual(data.duration, 1)
        } else { XCTFail("Expected note") }
    }

    func testDuplicateRepeatsAfterLongestSelectedNote() {
        let a = MIDIEvent.note(at: 1, pitch: 60, duration: 1)
        let b = MIDIEvent.note(at: 1.5, pitch: 67, duration: 1)
        var notes = [a, b]
        let ids = StudioMIDINoteEditing.duplicateSelected(in: &notes, ids: [a.id, b.id])
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(notes[2].beatPosition, 2.5)
        XCTAssertEqual(notes[3].beatPosition, 3)
    }

    func testResizeStartKeepsEndAndClampsToPositiveLength() {
        let note = MIDIEvent.note(at: 2, pitch: 60, duration: 2)
        let grown = StudioMIDINoteEditing.resizing([note], noteID: note.id,
                        edge: .start, beatDelta: 10, division: 0.25,
                        minimumDuration: 0.25)
        XCTAssertEqual(grown[0].beatPosition, 3.75)
        if case .note(let data) = grown[0].type {
            XCTAssertEqual(data.duration, 0.25)
        } else { XCTFail("Expected note") }
    }

    func testResizeEndSnapsAbsoluteEndInsteadOfDuration() {
        let note = MIDIEvent.note(at: 0.375, pitch: 60, duration: 0.5)
        let result = StudioMIDINoteEditing.resizing([note], noteID: note.id,
                      edge: .end, beatDelta: 0.01, division: 0.25)
        if case .note(let data) = result[0].type {
            XCTAssertEqual(data.duration, 0.625, accuracy: 0.000001)
        } else { XCTFail("Expected note") }
    }

    func testDeleteTargetsOnlyNotesNotControllers() {
        let note = MIDIEvent.note(at: 1, pitch: 60)
        let cc = MIDIEvent.controlChange(at: 2, controller: 11, value: 100)
        let kept = StudioMIDINoteEditing.deletingSelected(in: [note, cc],
                                                           ids: [note.id, cc.id])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].id, cc.id)
    }

    func testClickOnlyDoesNotQuantizeAnUnsnappedNote() {
        let note = MIDIEvent.note(at: 0.375, pitch: 60, duration: 0.5)
        let moved = StudioMIDINoteEditing.moving([note], selectedIDs: [note.id],
                    beatDelta: 0, pitchDelta: 0, division: 0.25)
        XCTAssertEqual(moved[0].beatPosition, 0.375)
        let resized = StudioMIDINoteEditing.resizing([note], noteID: note.id,
                       edge: .end, beatDelta: 0, division: 0.25)
        if case .note(let data) = resized[0].type {
            XCTAssertEqual(data.duration, 0.5)
        } else { XCTFail("Expected note") }
    }

    func testVerticalOnlyMoveKeepsOriginalTiming() {
        let note = MIDIEvent.note(at: 0.375, pitch: 60)
        let moved = StudioMIDINoteEditing.moving([note], selectedIDs: [note.id],
                    beatDelta: 0, pitchDelta: 2, division: 0.25)
        XCTAssertEqual(moved[0].beatPosition, 0.375)
        if case .note(let data) = moved[0].type {
            XCTAssertEqual(data.pitch, 62)
        } else { XCTFail("Expected note") }
    }

    func testOffsetRegionUsesAbsoluteGridAndPreservesLocalBounds() {
        let note = MIDIEvent.note(at: 0.375, pitch: 65, duration: 0.5)
        let moved = StudioMIDINoteEditing.moving(
            [note], selectedIDs: [note.id], beatDelta: 0.25,
            pitchDelta: 0, division: 0.25, clipStartBeat: 2.125
        )
        // 2.125 + 0.375 = 2.5. Move one quarter beat to 2.75.
        XCTAssertEqual(moved[0].beatPosition, 0.625)
        let clamped = StudioMIDINoteEditing.moving(
            [note], selectedIDs: [note.id], beatDelta: -10,
            pitchDelta: 0, division: 0.25, clipStartBeat: 2.125
        )
        XCTAssertEqual(clamped[0].beatPosition, 0)
    }

    func testResizeRespectsOffsetRegionStart() {
        let note = MIDIEvent.note(at: 0.25, pitch: 60, duration: 0.5)
        let resized = StudioMIDINoteEditing.resizing(
            [note], noteID: note.id, edge: .start,
            beatDelta: -10, division: 0.25, clipStartBeat: 8
        )
        XCTAssertEqual(resized[0].beatPosition, 0)
        if case .note(let data) = resized[0].type {
            XCTAssertEqual(data.duration, 0.75)
        } else { XCTFail("Expected note") }
    }

    func testPitchTranspositionKeepsChordIntervalsWhenApproachingMIDIClamp() {
        let a = MIDIEvent.note(at: 0, pitch: 120)
        let b = MIDIEvent.note(at: 0, pitch: 127)
        let moved = StudioMIDINoteEditing.moving([a, b], selectedIDs: [a.id,b.id],
                         beatDelta: 0, pitchDelta: 10, division: 0.25)
        if case .note(let first) = moved[0].type,
           case .note(let second) = moved[1].type {
            XCTAssertEqual(Int(second.pitch) - Int(first.pitch), 7)
        } else { XCTFail("Expected notes") }
    }
}
