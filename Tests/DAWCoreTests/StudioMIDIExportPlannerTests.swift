import XCTest
@testable import DAWCore

final class StudioMIDIExportPlannerTests: XCTestCase {
    private func makeTrack(
        start: Double = 0, length: Double = 4,
        notes: [MIDIEvent], other: [MIDIEvent] = [],
        map: StudioArticulationMap? = nil,
        assignments: [StudioNoteArticulation] = []
    ) -> Track {
        var track = Track(name: "Violin", type: .instrument)
        track.articulationMap = map
        var midi = MIDIClipData(events: notes + other)
        midi.articulations = assignments
        track.clips = [Clip(
            name: "Phrase",
            timeRange: TimeRange(
                start: TimePosition(beats: start, tempo: 120, sampleRate: 44_100),
                duration: TimePosition(beats: length, tempo: 120,
                                       sampleRate: 44_100)),
            content: .midi(midi))]
        return track
    }

    private func keyswitchMap() -> StudioArticulationMap {
        StudioArticulationMap(articulations: [
            StudioArticulationDefinition(id: "pizz", name: "Pizzicato",
                actions: [StudioArticulationAction(
                    kind: .keyswitch, number: 24, value: 99, channel: 0)])
        ])
    }

    func testMusicalOnlyDefaultDoesNotBakeSemanticArticulations() throws {
        let note = MIDIEvent.note(at: 0, pitch: 60, duration: 1)
        let cc = MIDIEvent.controlChange(at: 0, controller: 11, value: 78)
        let track = makeTrack(
            notes: [note], other: [cc], map: keyswitchMap(),
            assignments: [.init(noteID: note.id, articulationID: "pizz")])
        let messages = try StudioMIDIExportPlanner.messages(for: track, tempo: 120)
        XCTAssertEqual(messages.map(\.bytes), [
            [0xB0, 11, 78], [0x90, 60, 100], [0x80, 60, 0]
        ])
        XCTAssertEqual(messages.map(\.tick), [0, 0, 480])
        XCTAssertFalse(messages.contains(where: \.generatedArticulation))
        if case .midi(let original) = track.clips[0].content {
            XCTAssertEqual(original.articulations?.first?.articulationID, "pizz")
            XCTAssertEqual(original.events.count, 2)
        } else { XCTFail("MIDI clip was changed") }
    }

    func testPerformanceExportPlacesOneChordKeyswitchBeforeAllNotes() throws {
        let a = MIDIEvent.note(at: 0, pitch: 60)
        let b = MIDIEvent.note(at: 0, pitch: 64)
        let track = makeTrack(notes: [a, b], map: keyswitchMap(),
            assignments: [a, b].map {
                StudioNoteArticulation(noteID: $0.id, articulationID: "pizz")
            })
        let messages = try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120, mode: .renderedPerformance)
        let atStart = messages.filter { $0.tick == 0 }
        XCTAssertEqual(atStart.map(\.bytes), [
            [0x90, 24, 99], [0x90, 60, 100], [0x90, 64, 100]
        ])
        XCTAssertEqual(messages.filter { $0.bytes == [0x90, 24, 99] }.count, 1)
        XCTAssertEqual(messages.filter { $0.generatedArticulation }.count, 2)
    }

    func testPerformedControllersProgramsAndNoteChannelAreRendered() throws {
        let note = MIDIEvent.note(at: 0, pitch: 62, duration: 1)
        let map = StudioArticulationMap(articulations: [
            StudioArticulationDefinition(id: "short", name: "Short",
                actions: [
                    StudioArticulationAction(kind: .noteChannel, channel: 1),
                    StudioArticulationAction(kind: .programChange,
                        number: 7, channel: 1),
                    StudioArticulationAction(kind: .controller,
                        number: 68, value: 127, channel: 1)
                ])
        ])
        let track = makeTrack(notes: [note], map: map,
            assignments: [.init(noteID: note.id, articulationID: "short")])
        let messages = try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120, mode: .renderedPerformance)
        XCTAssertEqual(messages.map(\.bytes), [
            [0xC1, 7], [0xB1, 68, 127], [0x91, 62, 100], [0x81, 62, 0]
        ])
        XCTAssertEqual(messages.filter { $0.generatedArticulation }.count, 2)
        // A portable musical export preserves the authored channel.
        XCTAssertEqual(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120).first?.bytes, [0x90, 62, 100])
    }

    func testTrimsNoteOffAtRegionEndAndMaintainsSameTickOffPriority() throws {
        let long = MIDIEvent.note(at: 0.5, pitch: 60, duration: 8)
        let track = makeTrack(start: 4, length: 2, notes: [long])
        let messages = try StudioMIDIExportPlanner.messages(for: track, tempo: 120)
        XCTAssertEqual(messages.map(\.tick), [2160, 2880])
        if case .midi(let original) = track.clips[0].content,
           case .note(let data) = original.events[0].type {
            XCTAssertEqual(data.duration, 8, accuracy: 0.00001)
        } else { XCTFail("Original MIDI note was mutated") }

        let first = MIDIEvent.note(at: 0, pitch: 60, duration: 1)
        let second = MIDIEvent.note(at: 1, pitch: 60, duration: 1)
        let adjacent = try StudioMIDIExportPlanner.messages(
            for: makeTrack(notes: [first, second]), tempo: 120)
        XCTAssertEqual(adjacent.filter { $0.tick == 480 }.map(\.bytes), [
            [0x80, 60, 0], [0x90, 60, 100]
        ])
    }

    func testFullPrecisionPitchBendAndIndependentChannels() throws {
        let negative = MIDIEvent.pitchBend(at: 0, value: -8191, channel: 0)
        let positive = MIDIEvent.pitchBend(at: 1, value: 8191, channel: 1)
        let track = makeTrack(notes: [], other: [negative, positive])
        XCTAssertEqual(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120).map(\.bytes), [
            [0xE0, 0x01, 0x00], [0xE1, 0x7F, 0x7F]
        ])
    }

    func testMutingAndChannelFilterPreserveOnlyEligibleEvents() throws {
        let c0 = MIDIEvent.note(at: 0, pitch: 60, channel: 0)
        let c1 = MIDIEvent.note(at: 0, pitch: 65, channel: 1)
        var track = makeTrack(notes: [c0, c1])
        track.midiOutputChannel = 1
        XCTAssertEqual(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120).filter { $0.bytes[0] & 0xF0 == 0x90 }
            .map { $0.bytes[1] }, [65])
        track.isMuted = true
        XCTAssertTrue(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120).isEmpty)
    }

    func testRejectsUnsupportedLoopAndInvalidTempo() {
        var track = makeTrack(notes: [MIDIEvent.note(at: 0, pitch: 60)])
        track.clips[0].isLooped = true
        XCTAssertThrowsError(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 120)) { error in
            XCTAssertEqual(error as? StudioMIDIExportPlanningError,
                           .loopedRegionRequiresConsolidation)
        }
        XCTAssertThrowsError(try StudioMIDIExportPlanner.messages(
            for: track, tempo: 0)) { error in
            XCTAssertEqual(error as? StudioMIDIExportPlanningError, .invalidTempo)
        }
    }
}
