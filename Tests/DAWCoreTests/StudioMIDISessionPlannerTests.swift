import XCTest
@testable import DAWCore

final class StudioMIDISessionPlannerTests: XCTestCase {
    private func note(_ beat: Double, _ pitch: UInt8, duration: Double = 1,
                      channel: UInt8 = 0) -> MIDIEvent {
        MIDIEvent.note(at: beat, pitch: pitch, duration: duration, channel: channel)
    }

    private func trackWithClip(start: Double, length: Double,
                               events: [MIDIEvent],
                               assignments: [StudioNoteArticulation] = [],
                               map: StudioArticulationMap? = nil) -> Track {
        var track = Track(name: "Orchestra Violin", type: .instrument)
        track.articulationMap = map
        var midi = MIDIClipData(events: events)
        midi.articulations = assignments
        track.clips = [Clip(
            name: "Phrase",
            timeRange: TimeRange(
                start: TimePosition(beats: start, tempo: 120, sampleRate: 44100),
                duration: TimePosition(beats: length, tempo: 120,
                                       sampleRate: 44100)),
            content: .midi(midi))]
        return track
    }

    private func ksMap() -> StudioArticulationMap {
        StudioArticulationMap(name: "String KS", articulations: [
            StudioArticulationDefinition(
                id: "sustain", name: "Sustain",
                actions: [StudioArticulationAction(
                    kind: .keyswitch, number: 24, channel: 0)]),
            StudioArticulationDefinition(
                id: "pizzicato", name: "Pizzicato",
                actions: [StudioArticulationAction(
                    kind: .keyswitch, number: 29, channel: 0)])
        ])
    }

    func testSeekRestoresLastKeyswitchAndControllerWithoutRetriggeringOldNote() {
        let first = note(1, 60, duration: 3)
        let next = note(5, 62)
        let track = trackWithClip(
            start: 0, length: 8,
            events: [first,
                     MIDIEvent.controlChange(at: 2, controller: 11,
                                             value: 80),
                     MIDIEvent.controlChange(at: 3, controller: 1,
                                             value: 97),
                     next],
            assignments: [
                StudioNoteArticulation(noteID: first.id, articulationID: "pizzicato"),
                StudioNoteArticulation(noteID: next.id, articulationID: "sustain")
            ], map: ksMap())
        let rendered = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 3.5)
        XCTAssertTrue(rendered.allSatisfy { $0.absoluteBeat >= 3.5 })
        XCTAssertFalse(rendered.contains { $0.event.id == first.id })
        XCTAssertTrue(rendered.contains { $0.event.id == next.id })
        let restored = rendered.filter(\.restoresState)
        XCTAssertEqual(restored.count, 3)
        XCTAssertTrue(restored.allSatisfy { $0.absoluteBeat == 3.5 })
        XCTAssertTrue(restored.contains {
            if case .note(let note) = $0.event.type {
                return note.pitch == 29 && note.duration == 0.01
            }
            return false
        })
        XCTAssertTrue(restored.contains {
            if case .controlChange(let cc, let value) = $0.event.type {
                return cc == 11 && value == 80
            }
            return false
        })
        XCTAssertTrue(restored.contains {
            if case .controlChange(let cc, let value) = $0.event.type {
                return cc == 1 && value == 97
            }
            return false
        })
    }

    func testControllerAndProgramChangesFromEndedClipRemainAvailableAtSeek() {
        var track = trackWithClip(start: 0, length: 2,
            events: [MIDIEvent(beatPosition: 0.1, type: .programChange(program: 5)),
                     MIDIEvent.controlChange(at: 1, controller: 11, value: 70),
                     MIDIEvent.controlChange(at: 1.5, controller: 120, value: 0)])
        let later = note(0, 71)
        track.clips.append(Clip(
            name: "Later", timeRange: TimeRange(
                start: TimePosition(beats: 5, tempo: 120, sampleRate: 44100),
                duration: TimePosition(beats: 4, tempo: 120,
                                       sampleRate: 44100)),
            content: .midi(MIDIClipData(events: [later]))))
        let rendered = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 5)
        XCTAssertEqual(rendered.filter(\.restoresState).count, 2)
        XCTAssertFalse(rendered.filter(\.restoresState).contains {
            if case .controlChange(120, _) = $0.event.type { return true }
            return false
        })
        XCTAssertEqual(rendered.last?.event.id, later.id)
    }

    func testKeyswitchComesBeforeFirstNoteEvenAtRegionStart() {
        let chord = note(0, 60)
        let track = trackWithClip(start: 8, length: 4,
            events: [chord],
            assignments: [.init(noteID: chord.id, articulationID: "sustain")],
            map: ksMap())
        let rendered = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 8)
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered.map(\.absoluteBeat), [8, 8])
        if case .note(let ks) = rendered[0].event.type {
            XCTAssertEqual(ks.pitch, 24)
        } else { XCTFail("First event should be a keyswitch") }
        XCTAssertEqual(rendered[1].event.id, chord.id)
    }

    func testSimultaneousChordTriggersOneLatchingKeyswitch() {
        let notes = [note(0, 60), note(0, 64), note(0, 67)]
        let track = trackWithClip(start: 0, length: 4,
            events: notes,
            assignments: notes.map { .init(noteID: $0.id,
                                            articulationID: "sustain") },
            map: ksMap())
        let rendered = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 0)
        XCTAssertEqual(rendered.count, 4)
        XCTAssertEqual(rendered.filter {
            if case .note(let data) = $0.event.type {
                return data.pitch == 24
            }
            return false
        }.count, 1)
    }

    func testOverlappingHeldCCIsReleasedOnlyWhenLastVoiceEnds() {
        let a = note(0, 60, duration: 3)
        let b = note(1, 64, duration: 4)
        let map = StudioArticulationMap(articulations: [
            StudioArticulationDefinition(id: "legato", name: "Legato",
                actions: [StudioArticulationAction(
                    kind: .controller, number: 68, value: 127,
                    holdForNote: true)])])
        let track = trackWithClip(start: 0, length: 7, events: [a, b],
            assignments: [a, b].map { .init(noteID: $0.id,
                                             articulationID: "legato") },
            map: map)
        let events = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 0)
        let cc = events.compactMap { item -> (Double, UInt8)? in
            if case .controlChange(68, let value) = item.event.type {
                return (item.absoluteBeat, value)
            }
            return nil
        }
        XCTAssertEqual(cc.filter { $0.1 == 127 }.count, 2)
        let releases = cc.filter { $0.1 == 0 }
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.0 ?? -1, 4.999, accuracy: 0.002)
    }

    func testSeekAtLoopStartRehydratesEarlierStateOnEachLap() {
        let noteA = note(0, 60)
        let noteB = note(4, 62)
        let track = trackWithClip(start: 0, length: 8,
            events: [noteA, noteB],
            assignments: [.init(noteID: noteA.id, articulationID: "pizzicato")],
            map: ksMap())
        let first = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 3, until: 7)
        let second = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 3, until: 7)
        XCTAssertEqual(first.filter(\.restoresState).count, 1)
        XCTAssertEqual(second.filter(\.restoresState).count, 1)
        XCTAssertEqual(first.filter { $0.event.id == noteB.id }.count, 1)
        XCTAssertEqual(second.filter { $0.event.id == noteB.id }.count, 1)
        XCTAssertTrue(first.allSatisfy { $0.absoluteBeat < 7 })
        XCTAssertFalse(first.contains { $0.event.id == noteA.id })
    }

    func testDifferentMIDIChannelsMaintainIndependentArticulationStates() {
        let a = note(0, 60, channel: 0)
        let b = note(1, 64, channel: 1)
        let map = StudioArticulationMap(articulations: [
            StudioArticulationDefinition(id: "style", name: "Style",
                actions: [StudioArticulationAction(
                    kind: .controller, number: 68, value: 127,
                    channel: 0)])])
        var track = trackWithClip(start: 0, length: 6,
            events: [a, b,
                     MIDIEvent.controlChange(at: 0.3, controller: 1,
                                             value: 25, channel: 0),
                     MIDIEvent.controlChange(at: 1.5, controller: 1,
                                             value: 75, channel: 1)],
            assignments: [], map: map)
        track.articulationMap = nil
        let events = StudioMIDISessionPlanner.events(
            for: track, tempo: 120, from: 2)
        let restoredCC = events.filter(\.restoresState)
        XCTAssertEqual(restoredCC.count, 2)
        XCTAssertEqual(Set(restoredCC.map { $0.event.channel }),
                       Set([UInt8(0), UInt8(1)]))
    }

    func testCoreAudioPriorityIsNoteOffThenStateThenNoteOn() {
        XCTAssertLessThan(StudioMIDITransportOrder.priority(
            status: 0x80, data2: 0),
            StudioMIDITransportOrder.priority(
                status: 0xB0, data2: 127))
        XCTAssertLessThan(StudioMIDITransportOrder.priority(
            status: 0xB0, data2: 127),
            StudioMIDITransportOrder.priority(
                status: 0x90, data2: 100))
    }
}
