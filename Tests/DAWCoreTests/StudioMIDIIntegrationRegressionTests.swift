import Foundation
import XCTest
@testable import DAWCore

/// Milestone 14: verify the shared Studio project model survives an entire
/// orchestral export/import workflow without changing instruments, stage
/// controls, semantic articulations or source MIDI clips.
final class StudioMIDIIntegrationRegressionTests: XCTestCase {
    private func makeClip(start: Double, length: Double,
                          events: [MIDIEvent]) -> Clip {
        Clip(name: "MIDI Phrase",
             timeRange: TimeRange(
                start: TimePosition(beats: start, tempo: 120),
                duration: TimePosition(beats: length, tempo: 120)),
             content: .midi(MIDIClipData(events: events)))
    }

    private func fixture() -> Project {
        var project = Project(name: "Studio MIDI Orchestra")
        project.tempo = Tempo(bpm: 120)
        project.timeSignature = .sixEight
        project.tempoChanges = [
            TempoChange(beatPosition: 6, tempo: Tempo(bpm: 90))
        ]

        let lead = MIDIEvent.note(
            at: 0.5, pitch: 67, velocity: 91, duration: 4, channel: 0)
        var silent = MIDIEvent.note(
            at: 0, pitch: 36, velocity: 100, duration: 1, channel: 0)
        if case .note(var data) = silent.type {
            data.isMuted = true
            silent.type = .note(data)
        }
        let expression = MIDIEvent.controlChange(
            at: 0.25, controller: 11, value: 87, channel: 0)

        var strings = Track(name: "Garritan Violins", type: .instrument)
        strings.garritanProgramID = "gpo5:violins"
        strings.stageReverbZone = 4
        strings.stageWetTrim = 0.75
        strings.articulationMap = StudioArticulationMap(
            name: "Custom Bowing",
            articulations: [
                StudioArticulationDefinition(
                    id: "pizz", name: "Pizzicato", actions: [
                        StudioArticulationAction(
                            kind: .keyswitch, number: 24, value: 99, channel: 0),
                        StudioArticulationAction(
                            kind: .controller, number: 68, value: 127, channel: 0)
                    ])
            ])
        var stringsClip = makeClip(
            start: 3, length: 2, events: [lead, silent, expression])
        if case .midi(var midi) = stringsClip.content {
            midi.articulations = [
                StudioNoteArticulation(noteID: lead.id, articulationID: "pizz"),
                StudioNoteArticulation(noteID: silent.id, articulationID: "pizz")
            ]
            stringsClip.content = .midi(midi)
        }
        strings.clips = [stringsClip]

        var winds = Track(name: "Studio Synth Winds", type: .instrument)
        winds.studioSynthEnabled = true
        winds.clips = [makeClip(
            start: 0, length: 4,
            events: [.note(at: 0, pitch: 72, velocity: 80,
                           duration: 1, channel: 1)])]

        let audio = Track(name: "Mic Recording", type: .audio)
        project.tracks = [strings, winds, audio]
        return project
    }

    func testProjectRemainsEditableAndSilentNotesNeverExport() throws {
        let project = fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(project)

        let musical = try StandardMIDIFileExporter.encode(project: project)
        let performance = try StandardMIDIFileExporter.encode(
            project: project, mode: .renderedPerformance)
        let importedMusical = try StandardMIDIFileImporter.decode(
            musical, name: "Musical")
        let importedPerformance = try StandardMIDIFileImporter.decode(
            performance, name: "Performance")

        XCTAssertEqual(importedMusical.tracks.map(\.name), [
            "Garritan Violins", "Studio Synth Winds"
        ])
        XCTAssertEqual(importedPerformance.tracks.map(\.name), [
            "Garritan Violins", "Studio Synth Winds"
        ])
        XCTAssertEqual(importedMusical.timeSignature, .sixEight)
        XCTAssertEqual(importedMusical.tempoChanges.count, 1)
        XCTAssertEqual(importedMusical.tempoChanges.first?.beatPosition, 6)

        func pitches(_ project: Project) -> [UInt8] {
            guard case .midi(let midi) = project.tracks[0].clips[0].content else {
                return []
            }
            return midi.events.compactMap { event in
                guard case .note(let note) = event.type, note.velocity > 0
                    else { return nil }
                return note.pitch
            }
        }
        XCTAssertEqual(pitches(importedMusical), [67])
        XCTAssertEqual(Set(pitches(importedPerformance)),
                       Set([UInt8(24), UInt8(67)]))
        // MIDI performance export is a *copy*: original project state,
        // audition routing, and note-identity metadata are unchanged.
        XCTAssertEqual(try encoder.encode(project), before)
        XCTAssertEqual(project.tracks[0].garritanProgramID, "gpo5:violins")
        XCTAssertEqual(project.tracks[0].stageReverbZone, 4)
        XCTAssertEqual(project.tracks[0].stageWetTrim, 0.75)
        XCTAssertEqual(project.tracks[1].studioSynthEnabled, true)
        if case .midi(let source) = project.tracks[0].clips[0].content {
            XCTAssertEqual(source.articulations?.count, 2)
            XCTAssertEqual(source.events.count, 3)
            XCTAssertEqual(source.events.first?.id, source.articulations?.first?.noteID)
        } else { XCTFail("Exporter modified the authored phrase") }
    }

    func testLiveSessionAndMusicalExportShareTrimAndMuteBoundary() throws {
        let project = fixture()
        let strings = project.tracks[0]
        let session = StudioMIDISessionPlanner.events(
            for: strings, tempo: project.tempo.bpm, from: 0)
        let livePitches = session.compactMap { entry -> UInt8? in
            if case .note(let note) = entry.event.type, note.velocity > 0,
               note.pitch >= 60 {
                return note.pitch
            }
            return nil
        }
        XCTAssertEqual(livePitches, [67])
        let messages = try StudioMIDIExportPlanner.messages(
            for: strings, tempo: project.tempo.bpm)
        // Leading CC at absolute beat 3.25, musical note at 3.5 and
        // hard clip trim at 5.0 (not the authored note end at 7.5).
        XCTAssertEqual(messages.map(\.tick), [1560, 1680, 2400])
        XCTAssertEqual(messages.map(\.bytes), [
            [0xB0, 11, 87], [0x90, 67, 91], [0x80, 67, 0]
        ])
    }

    func testAtomicExportFailureDoesNotOverwritePreviousMixAndMIDIFile() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Studio-MIDI-M14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("orchestra.mid")

        let manager = ProjectFileManager()
        let good = fixture()
        try await manager.export(project: good, to: file, format: .midi)
        let saved = try Data(contentsOf: file)
        XCTAssertEqual(Array(saved.prefix(4)), Array("MThd".utf8))

        var invalid = good
        invalid.tempoChanges = [
            TempoChange(beatPosition: 4, tempo: Tempo(bpm: 95),
                        curveType: .linear)
        ]
        do {
            try await manager.export(
                project: invalid, to: file, format: .midiPerformance)
            XCTFail("Export must reject a non-step tempo curve")
        } catch {
            XCTAssertEqual(try Data(contentsOf: file), saved,
                           "A failed export must not destroy the previous .mid")
        }
    }
}
