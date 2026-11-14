import Foundation
import XCTest
@testable import DAWCore

final class StudioMIDINoteMuteTests: XCTestCase {
    private func makeTrack(note: MIDIEvent, map: StudioArticulationMap? = nil,
                           articulationID: String? = nil) -> Track {
        var midi = MIDIClipData(events: [note])
        if let articulationID {
            midi.articulations = [
                StudioNoteArticulation(
                    noteID: note.id, articulationID: articulationID)
            ]
        }
        var track = Track(name: "Strings", type: .instrument)
        track.articulationMap = map
        track.clips = [Clip(name: "Phrase", timeRange: TimeRange(
            start: TimePosition(beats: 0, tempo: 120),
            duration: TimePosition(beats: 4, tempo: 120)),
            content: .midi(midi))]
        return track
    }

    func testMutedNoteSuppressesSoundInLivePlaybackAndBothExportModes() throws {
        var note = MIDIEvent.note(at: 1, pitch: 64, duration: 2)
        if case .note(var data) = note.type {
            data.isMuted = true
            note.type = .note(data)
        }
        let map = StudioArticulationMap(articulations: [
            StudioArticulationDefinition(id: "pizz", name: "Pizz", actions: [
                StudioArticulationAction(
                    kind: .keyswitch, number: 24, value: 100)
            ])
        ])
        let track = makeTrack(note: note, map: map, articulationID: "pizz")
        XCTAssertTrue(StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 0).isEmpty)
        XCTAssertTrue(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120).isEmpty)
        XCTAssertTrue(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120, mode: .renderedPerformance).isEmpty)

        // The muted note and its articulation assignment must remain saved.
        if case .midi(let midi) = track.clips[0].content {
            XCTAssertEqual(midi.events.first?.id, note.id)
            XCTAssertEqual(midi.articulations?.first?.noteID, note.id)
        } else { XCTFail("Saved clip lost MIDI content") }
    }

    func testMutingOneNoteDoesNotMuteOtherNotesOrAuthoredControllers() throws {
        var muted = MIDIEvent.note(at: 0, pitch: 60, duration: 1)
        if case .note(var data) = muted.type {
            data.isMuted = true
            muted.type = .note(data)
        }
        let audible = MIDIEvent.note(at: 0.5, pitch: 67, duration: 1)
        let expression = MIDIEvent.controlChange(at: 0, controller: 11, value: 82)
        var track = makeTrack(note: audible)
        if case .midi(var midi) = track.clips[0].content {
            midi.events = [muted, audible, expression]
            track.clips[0].content = .midi(midi)
        }
        let messages = try StudioMIDIExportPlanner.messages(for: track, tempo: 120)
        XCTAssertEqual(messages.filter { $0.bytes[0] & 0xF0 == 0x90 }
            .map { $0.bytes[1] }, [67])
        XCTAssertTrue(messages.contains { $0.bytes == [0xB0, 11, 82] })
    }

    func testMutedStateIsOptionalForBackwardCompatibleJSONDecode() throws {
        // Old projects encode no isMuted property. New projects can encode
        // explicit true/false without changing their saved note IDs.
        let original = NoteData(pitch: 60, velocity: 99, duration: 1.75)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteData.self, from: data)
        XCTAssertNil(decoded.isMuted)

        var muted = original
        muted.isMuted = true
        let saved = try JSONEncoder().encode(muted)
        let restored = try JSONDecoder().decode(NoteData.self, from: saved)
        XCTAssertEqual(restored.isMuted, true)
        XCTAssertEqual(restored.pitch, original.pitch)
        XCTAssertEqual(restored.duration, original.duration)
    }
}
