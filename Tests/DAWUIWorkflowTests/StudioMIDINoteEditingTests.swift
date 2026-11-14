import XCTest
import DAWCore
@testable import DAWUI

final class StudioMIDINoteEditingTests: XCTestCase {
    func testKeyboardNudgeDoesNotQuantizeUnsnappedPhrase() {
        let a = MIDIEvent.note(at: 0.375, pitch: 60, duration: 0.7)
        let b = MIDIEvent.note(at: 0.625, pitch: 64, duration: 1)
        let cc = MIDIEvent.controlChange(at: 0.5, controller: 11, value: 91)
        let result = StudioMIDINoteEditing.nudging(
            [a, b, cc], selectedIDs: [a.id, b.id],
            beatDelta: 0.25, pitchDelta: 0)
        XCTAssertEqual(result[0].beatPosition, 0.625)
        XCTAssertEqual(result[1].beatPosition, 0.875)
        XCTAssertEqual(result[1].beatPosition - result[0].beatPosition, 0.25)
        XCTAssertEqual(result[2].beatPosition, 0.5)
        XCTAssertEqual(result[0].id, a.id)
        XCTAssertEqual(result[1].id, b.id)
        XCTAssertTrue(StudioMIDINoteEditing.hasPitchOrTimingChanges(
            before: [a,b,cc], after: result))
    }

    func testPitchNudgePreservesChordIntervalsAtMIDILimit() {
        let a = MIDIEvent.note(at: 1, pitch: 119)
        let b = MIDIEvent.note(at: 1, pitch: 127)
        let raised = StudioMIDINoteEditing.nudging(
            [a,b], selectedIDs: [a.id,b.id], pitchDelta: 12)
        XCTAssertFalse(StudioMIDINoteEditing.hasPitchOrTimingChanges(
            before: [a,b], after: raised))
        let lowered = StudioMIDINoteEditing.nudging(
            [a,b], selectedIDs: [a.id,b.id], pitchDelta: -12)
        if case .note(let low) = lowered[0].type,
           case .note(let high) = lowered[1].type {
            XCTAssertEqual(low.pitch, 107)
            XCTAssertEqual(high.pitch, 115)
            XCTAssertEqual(Int(high.pitch) - Int(low.pitch), 8)
        } else { XCTFail("Expected pitched notes") }
    }

    func testNegativeNudgeClampsWholeSelectionWithoutCompression() {
        let a = MIDIEvent.note(at: 0.125, pitch: 60)
        let b = MIDIEvent.note(at: 0.875, pitch: 67)
        let moved = StudioMIDINoteEditing.nudging(
            [a,b], selectedIDs: [a.id,b.id], beatDelta: -2)
        XCTAssertEqual(moved[0].beatPosition, 0)
        XCTAssertEqual(moved[1].beatPosition, 0.75)
        XCTAssertFalse(StudioMIDINoteEditing.hasPitchOrTimingChanges(
            before: moved, after: moved))
    }

    func testNudgeDoesNotTouchUnselectedNotesOrControllers() {
        let selected = MIDIEvent.note(at: 1, pitch: 60)
        let other = MIDIEvent.note(at: 2, pitch: 67)
        let cc = MIDIEvent.controlChange(at: 1, controller: 11, value: 55)
        let moved = StudioMIDINoteEditing.nudging(
            [selected,other,cc], selectedIDs: [selected.id],
            beatDelta: 0.125, pitchDelta: 1)
        XCTAssertEqual(moved[1].id, other.id)
        XCTAssertEqual(moved[1].beatPosition, 2)
        XCTAssertEqual(moved[2].id, cc.id)
        XCTAssertEqual(moved[2].beatPosition, 1)
        if case .note(let data) = moved[0].type {
            XCTAssertEqual(data.pitch, 61)
        } else { XCTFail("Expected edited note") }
    }

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
    func testSplitAtPlayheadPreservesIDPitchAndTotalDuration() {
        let note = MIDIEvent.note(at: 1, pitch: 60, velocity: 87, duration: 3)
        let cc = MIDIEvent.controlChange(at: 2, controller: 11, value: 93)
        let result = StudioMIDINoteEditing.splitting(
            [note, cc], selectedIDs: [note.id], at: 2.25)
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[0].id, note.id)
        XCTAssertEqual(result.events[1].id, result.idMapping[note.id])
        XCTAssertNotEqual(result.events[1].id, note.id)
        XCTAssertEqual(result.events[0].beatPosition, 1)
        XCTAssertEqual(result.events[1].beatPosition, 2.25)
        XCTAssertEqual(result.events[2].id, cc.id)
        if case .note(let left) = result.events[0].type,
           case .note(let right) = result.events[1].type {
            XCTAssertEqual(left.duration, 1.25, accuracy: 0.000001)
            XCTAssertEqual(right.duration, 1.75, accuracy: 0.000001)
            XCTAssertEqual(left.pitch, right.pitch)
            XCTAssertEqual(left.velocity, right.velocity)
            XCTAssertEqual(left.duration + right.duration, 3, accuracy: 0.000001)
        } else { XCTFail("Split lost one of its note halves") }
    }

    func testSplitIsNoOpAtNoteEdgesAndOnNonSelectedNotes() {
        let a = MIDIEvent.note(at: 0.5, pitch: 65, duration: 2)
        let b = MIDIEvent.note(at: 0.5, pitch: 67, duration: 2)
        for beat in [0.5, 2.5, 5] {
            let result = StudioMIDINoteEditing.splitting(
                [a, b], selectedIDs: [a.id], at: beat)
            XCTAssertTrue(result.idMapping.isEmpty)
            XCTAssertEqual(result.events.map(\.id), [a.id, b.id])
        }
        let result = StudioMIDINoteEditing.splitting(
            [a, b], selectedIDs: [a.id], at: 1)
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[2].id, b.id)
    }

    func testGlueCompatibleNotesKeepsFirstIdentityAndControllers() {
        let a = MIDIEvent.note(at: 0, pitch: 60, velocity: 92, duration: 1)
        let b = MIDIEvent.note(at: 1, pitch: 60, velocity: 92, duration: 0.5)
        let c = MIDIEvent.note(at: 1.5, pitch: 60, velocity: 92, duration: 1)
        let cc = MIDIEvent.controlChange(at: 0.25, controller: 1, value: 70)
        let result = StudioMIDINoteEditing.gluing(
            [a, cc, b, c], selectedIDs: [a.id, b.id, c.id],
            articulations: [a.id: "legato", b.id: "legato", c.id: "legato"])
        XCTAssertEqual(result.events.map(\.id), [a.id, cc.id])
        XCTAssertEqual(result.removedIDs, [b.id, c.id])
        if case .note(let merged) = result.events[0].type {
            XCTAssertEqual(merged.duration, 2.5, accuracy: 0.000001)
        } else { XCTFail("Glue failed") }
    }

    func testGlueRefusesGapsDifferentVelocityChannelsOrArticulations() {
        let first = MIDIEvent.note(at: 0, pitch: 60, velocity: 100, duration: 1)
        let separated = MIDIEvent.note(at: 1.1, pitch: 60, velocity: 100)
        let differentVelocity = MIDIEvent.note(at: 1, pitch: 60, velocity: 80)
        let differentChannel = MIDIEvent.note(at: 1, pitch: 60, channel: 2)
        let matching = MIDIEvent.note(at: 1, pitch: 60)
        for bad in [separated, differentVelocity, differentChannel] {
            let merged = StudioMIDINoteEditing.gluing(
                [first, bad], selectedIDs: [first.id, bad.id])
            XCTAssertTrue(merged.removedIDs.isEmpty)
        }
        let mismatch = StudioMIDINoteEditing.gluing(
            [first, matching], selectedIDs: [first.id, matching.id],
            articulations: [first.id: "arco", matching.id: "pizz"])
        XCTAssertTrue(mismatch.removedIDs.isEmpty)
    }

    func testMuteTogglesIndividuallyAndKeepsControllers() {
        let a = MIDIEvent.note(at: 0, pitch: 60)
        let b = MIDIEvent.note(at: 1, pitch: 64)
        let cc = MIDIEvent.controlChange(at: 0, controller: 11, value: 80)
        let muted = StudioMIDINoteEditing.togglingMute(
            [a, b, cc], selectedIDs: [a.id, cc.id])
        if case .note(let data) = muted[0].type {
            XCTAssertEqual(data.isMuted, true)
        } else { XCTFail("Note disappeared") }
        XCTAssertEqual(muted[1].id, b.id)
        XCTAssertEqual(muted[2].id, cc.id)
        let unmuted = StudioMIDINoteEditing.togglingMute(
            muted, selectedIDs: [a.id])
        if case .note(let data) = unmuted[0].type {
            XCTAssertEqual(data.isMuted, false)
        } else { XCTFail("Note disappeared after unmute") }
    }

    func testQuantizeUsesAbsoluteGridAndClampsRegionLocalStart() {
        let note = MIDIEvent.note(at: 0.1, pitch: 72)
        let cc = MIDIEvent.controlChange(at: 0.1, controller: 1, value: 87)
        // Source region starts at 2.125 quarter-note beats. Quantizing
        // absolute 2.225 to 2.0 would be before the source region.
        let changed = StudioMIDINoteEditing.quantizing(
            [note, cc], selectedIDs: [note.id, cc.id],
            division: 0.5, clipStartBeat: 2.125)
        XCTAssertEqual(changed[0].beatPosition, 0)
        XCTAssertEqual(changed[1].beatPosition, cc.beatPosition)
        XCTAssertEqual(note.beatPosition, 0.1)
        let other = MIDIEvent.note(at: 0.375, pitch: 67)
        let snapped = StudioMIDINoteEditing.quantizing(
            [other], selectedIDs: [other.id],
            division: 0.25, clipStartBeat: 0.125)
        XCTAssertEqual(snapped[0].beatPosition, 0.375)
        XCTAssertFalse(StudioMIDINoteEditing.hasPitchOrTimingChanges(
            before: [other], after: snapped))
    }

    func testSplitAndGluePreserveSemanticArticulationAssignments() {
        let original = MIDIEvent.note(at: 0, pitch: 69, duration: 2)
        var midi = MIDIClipData(events: [original])
        midi.articulations = [
            StudioNoteArticulation(noteID: original.id, articulationID: "sustain")
        ]
        let split = StudioMIDINoteEditing.splitting(
            midi.events, selectedIDs: [original.id], at: 1)
        guard let rightID = split.idMapping[original.id] else {
            return XCTFail("No split destination ID")
        }
        let copied = StudioArticulationAssignmentEditing.byNoteID(in: midi)
        midi.events = split.events
        StudioArticulationAssignmentEditing.transfer(
            from: copied, idMapping: split.idMapping, into: &midi)
        XCTAssertEqual(StudioArticulationAssignmentEditing.byNoteID(in: midi)[rightID],
                       "sustain")
        let merged = StudioMIDINoteEditing.gluing(
            midi.events, selectedIDs: [original.id, rightID],
            articulations: StudioArticulationAssignmentEditing.byNoteID(in: midi))
        XCTAssertEqual(merged.removedIDs, [rightID])
        midi.events = merged.events
        midi.articulations?.removeAll { merged.removedIDs.contains($0.noteID) }
        XCTAssertEqual(midi.events.count, 1)
        XCTAssertEqual(midi.events[0].id, original.id)
        XCTAssertEqual(StudioArticulationAssignmentEditing.byNoteID(in: midi),
                       [original.id: "sustain"])
    }

}
