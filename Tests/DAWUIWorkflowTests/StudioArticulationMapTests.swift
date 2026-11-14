import XCTest
import DAWCore
@testable import DAWUI

final class StudioArticulationMapTests: XCTestCase {
    private func makeMap() -> StudioArticulationMap {
        StudioArticulationMap(name: "Test Violin", articulations: [
            StudioArticulationDefinition(id: "pizzicato", name: "Pizzicato",
                actions: [StudioArticulationAction(kind: .keyswitch,
                    number: 24, value: 100, channel: 0)]),
            StudioArticulationDefinition(id: "legato", name: "Legato",
                actions: [StudioArticulationAction(kind: .controller,
                    number: 68, value: 127, channel: 0)])
        ])
    }

    func testAssignmentsPreserveNoteEventsAndOriginalPitch() {
        let note = MIDIEvent.note(at: 2, pitch: 69, duration: 1.5)
        var midi = MIDIClipData(events: [note])
        XCTAssertTrue(StudioArticulationAssignmentEditing.assign("pizzicato",
                         to: [note.id], in: &midi))
        XCTAssertEqual(midi.events.count, 1)
        XCTAssertEqual(midi.events[0].id, note.id)
        if case .note(let data) = midi.events[0].type {
            XCTAssertEqual(data.pitch, 69)
            XCTAssertEqual(data.duration, 1.5)
        } else { XCTFail("Expected original note") }
        XCTAssertEqual(midi.articulations?.first?.articulationID, "pizzicato")
    }

    func testPlaybackSynthesizesKeyswitchBeforeNoteWithoutPersistingIt() {
        let note = MIDIEvent.note(at: 2, pitch: 69, duration: 1)
        var midi = MIDIClipData(events: [note])
        _ = StudioArticulationAssignmentEditing.assign("pizzicato", to: [note.id], in: &midi)
        let playback = StudioArticulationRenderer.events(for: midi, map: makeMap())
        XCTAssertEqual(midi.events.count, 1)
        XCTAssertEqual(playback.count, 2)
        XCTAssertLessThan(playback[0].beatPosition, playback[1].beatPosition)
        if case .note(let trigger) = playback[0].type {
            XCTAssertEqual(trigger.pitch, 24)
            XCTAssertEqual(trigger.velocity, 100)
        } else { XCTFail("Expected generated keyswitch") }
        XCTAssertEqual(playback[1].id, note.id)
    }

    func testRemapCommandsWithoutChangingMusicalAssignment() {
        let note = MIDIEvent.note(at: 0, pitch: 60)
        var midi = MIDIClipData(events: [note])
        _ = StudioArticulationAssignmentEditing.assign("pizzicato", to: [note.id], in: &midi)
        let first = StudioArticulationRenderer.events(for: midi, map: makeMap())
        var updated = makeMap()
        updated.articulations[0].actions[0].number = 31
        let second = StudioArticulationRenderer.events(for: midi, map: updated)
        if case .note(let before) = first[0].type,
           case .note(let after) = second[0].type {
            XCTAssertEqual(before.pitch, 24)
            XCTAssertEqual(after.pitch, 31)
        } else { XCTFail("Expected keyswitch events") }
        XCTAssertEqual(midi.articulations?.first?.articulationID, "pizzicato")
        XCTAssertEqual(midi.events[0].id, note.id)
    }

    func testControllerMapAndChannelSwitching() {
        let note = MIDIEvent.note(at: 1, pitch: 65, channel: 0)
        var midi = MIDIClipData(events: [note])
        _ = StudioArticulationAssignmentEditing.assign("legato", to: [note.id], in: &midi)
        var map = makeMap()
        map.articulations[1].actions.insert(
            StudioArticulationAction(kind: .noteChannel,
                                     channel: 3), at: 0)
        let result = StudioArticulationRenderer.events(for: midi, map: map)
        XCTAssertEqual(result.count, 2)
        if case .controlChange(let cc, let value) = result[0].type {
            XCTAssertEqual(cc, 68)
            XCTAssertEqual(value, 127)
        } else { XCTFail("Expected CC68") }
        XCTAssertEqual(result[1].channel, 3)
        XCTAssertEqual(midi.events[0].channel, 0)
    }

    func testCombinedActionsProgramAndController() {
        let note = MIDIEvent.note(at: 3, pitch: 60, duration: 2)
        var midi = MIDIClipData(events: [note])
        _ = StudioArticulationAssignmentEditing.assign("mixed", to: [note.id], in: &midi)
        let combined = StudioArticulationDefinition(id: "mixed", name: "Hybrid",
            actions: [
                StudioArticulationAction(kind: .programChange,
                                        number: 14, channel: 2),
                StudioArticulationAction(kind: .controller,
                                        number: 11, value: 95, channel: 2)
            ])
        let result = StudioArticulationRenderer.events(
            for: midi, map: StudioArticulationMap(articulations: [combined]))
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.contains { if case .programChange(14) = $0.type { return true }
                                         return false })
        XCTAssertTrue(result.contains { if case .controlChange(11, 95) = $0.type {
                                          return true
                                      }; return false })
    }

    func testAssignmentDeletionDoesNotDeleteOtherAssignments() {
        let a = MIDIEvent.note(at: 0, pitch: 60)
        let b = MIDIEvent.note(at: 1, pitch: 64)
        var midi = MIDIClipData(events: [a, b])
        _ = StudioArticulationAssignmentEditing.assign("legato", to: [a.id, b.id], in: &midi)
        _ = StudioArticulationAssignmentEditing.assign(nil, to: [a.id], in: &midi)
        XCTAssertEqual(midi.articulations?.count, 1)
        XCTAssertEqual(midi.articulations?.first?.noteID, b.id)
        XCTAssertEqual(midi.articulations?.first?.articulationID, "legato")
    }

    func testUnknownArticulationHasNoTransportSideEffects() {
        let note = MIDIEvent.note(at: 0, pitch: 60)
        var midi = MIDIClipData(events: [note])
        _ = StudioArticulationAssignmentEditing.assign("not-found", to: [note.id], in: &midi)
        let result = StudioArticulationRenderer.events(for: midi, map: makeMap())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, note.id)
    }

    func testProjectArticulationsAndMapRoundTrip() throws {
        var track = Track(name: "Violin", type: .instrument)
        track.articulationMap = makeMap()
        let note = MIDIEvent.note(at: 1, pitch: 60)
        var midi = MIDIClipData(events: [note])
        _ = StudioArticulationAssignmentEditing.assign("legato", to: [note.id], in: &midi)
        let decodedTrack = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track))
        let decodedMIDI = try JSONDecoder().decode(
            MIDIClipData.self, from: JSONEncoder().encode(midi))
        XCTAssertEqual(decodedTrack.articulationMap, track.articulationMap)
        XCTAssertEqual(decodedMIDI.articulations, midi.articulations)
    }

    func testOldMIDIFilesDecodeWithoutArticulations() throws {
        let note = MIDIEvent.note(at: 0, pitch: 60)
        let modern = MIDIClipData(events: [note])
        let bytes = try JSONEncoder().encode(modern)
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes)
                                      as? [String: Any])
        dictionary.removeValue(forKey: "articulations")
        let oldData = try JSONSerialization.data(withJSONObject: dictionary)
        let decoded = try JSONDecoder().decode(MIDIClipData.self, from: oldData)
        XCTAssertNil(decoded.articulations)
        XCTAssertEqual(decoded.events.count, 1)
    }
}
