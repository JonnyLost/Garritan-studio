import Foundation
import XCTest
@testable import DAWCore

final class StandardMIDIFileImporterTests: XCTestCase {
    private func events(_ project: Project, track: Int = 0) -> [MIDIEvent] {
        guard project.tracks.indices.contains(track),
              let clip = project.tracks[track].clips.first,
              case .midi(let midi) = clip.content else { return [] }
        return midi.events
    }

    private func chunk(_ bytes: [UInt8]) -> [UInt8] {
        let length = bytes.count
        return Array("MTrk".utf8) + [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)
        ] + bytes
    }

    private func formatZero(_ body: [UInt8], division: UInt16 = 480) -> Data {
        Data(Array("MThd".utf8) +
            [0, 0, 0, 6, 0, 0, 0, 1, UInt8(division >> 8),
             UInt8(division & 0xFF)] + chunk(body))
    }

    func testExportImportExportPreservesTracksTempoMeterAndExpression() throws {
        var project = Project(name: "Orchestra")
        project.tempo = Tempo(bpm: 120)
        project.tempoChanges = [
            TempoChange(beatPosition: 4, tempo: Tempo(bpm: 90))
        ]
        project.timeSignatureChanges = [
            TimeSignatureChange(
                beatPosition: 8,
                timeSignature: TimeSignature(numerator: 6, denominator: 8))
        ]
        var winds = Track(name: "Woodwinds", type: .midi)
        winds.clips = [Clip(name: "Wind Line", timeRange: TimeRange(
            start: TimePosition(beats: 0, tempo: 120),
            duration: TimePosition(beats: 12, tempo: 120)),
            content: .midi(MIDIClipData(events: [
                MIDIEvent.note(at: 0, pitch: 72, velocity: 85,
                               duration: 1.5, channel: 2),
                .controlChange(at: 0.5, controller: 11,
                               value: 91, channel: 2),
                .pitchBend(at: 1, value: -1234, channel: 2),
                MIDIEvent(beatPosition: 2,
                          type: .programChange(program: 41), channel: 2),
                MIDIEvent(beatPosition: 3,
                          type: .aftertouch(pressure: 60), channel: 2)
            ])))]
        var strings = Track(name: "Strings", type: .instrument)
        strings.clips = [Clip(name: "Strings", timeRange: TimeRange(
            start: TimePosition(beats: 0, tempo: 120),
            duration: TimePosition(beats: 6, tempo: 120)),
            content: .midi(MIDIClipData(events: [
                MIDIEvent.note(at: 4, pitch: 60, duration: 2)
            ])))]
        project.tracks = [winds, strings]

        let imported = try StandardMIDIFileImporter.decode(
            StandardMIDIFileExporter.encode(project: project),
            name: "Reimported"
        )
        XCTAssertEqual(imported.name, "Reimported")
        XCTAssertEqual(imported.tracks.map(\.name), ["Woodwinds", "Strings"])
        XCTAssertEqual(imported.tempo.bpm, 120, accuracy: 0.001)
        XCTAssertEqual(imported.tempoChanges.count, 1)
        XCTAssertEqual(imported.tempoChanges[0].beatPosition, 4, accuracy: 0.001)
        XCTAssertEqual(imported.tempoChanges[0].tempo.bpm, 90, accuracy: 0.001)
        XCTAssertEqual(imported.timeSignatureChanges.count, 1)
        XCTAssertEqual(imported.timeSignatureChanges[0].beatPosition, 8)
        XCTAssertEqual(imported.timeSignatureChanges[0].timeSignature,
                       TimeSignature(numerator: 6, denominator: 8))
        let wind = events(imported)
        XCTAssertEqual(wind.count, 5)
        XCTAssertTrue(wind.contains {
            if case .pitchBend(-1234) = $0.type { return $0.channel == 2 }
            return false
        })
        XCTAssertTrue(wind.contains {
            if case .controlChange(11, 91) = $0.type { return $0.channel == 2 }
            return false
        })
        XCTAssertTrue(wind.contains {
            if case .note(let note) = $0.type {
                return note.pitch == 72 && note.duration == 1.5 &&
                    $0.channel == 2
            }
            return false
        })
        let second = try StandardMIDIFileExporter.encode(project: imported)
        let importedAgain = try StandardMIDIFileImporter.decode(second)
        XCTAssertEqual(importedAgain.tracks.count, 2)
        XCTAssertEqual(events(importedAgain).count, 5)
        XCTAssertEqual(events(importedAgain, track: 1).count, 1)
    }

    func testFormatZeroRunningStatusAndOverlappingNotes() throws {
        // Two same-channel notes, with running status for both Note On and
        // Note Off, and proper note pairing. Original division is 480 PPQ.
        let bytes: [UInt8] = [
            0x00, 0xFF, 0x03, 0x05, 0x50, 0x69, 0x61, 0x6E, 0x6F,
            0x00, 0x90, 60, 100,
            0x78, 64, 90,             // 120 ticks: running Note On
            0x82, 0x68, 0x80, 60, 42, // 360 more ticks: Note Off at 480
            0x00, 64, 35,             // running Note Off at 480
            0x00, 0xFF, 0x2F, 0x00
        ]
        let imported = try StandardMIDIFileImporter.decode(formatZero(bytes))
        XCTAssertEqual(imported.tracks.count, 1)
        XCTAssertEqual(imported.tracks[0].name, "Piano")
        let notes = events(imported)
        XCTAssertEqual(notes.count, 2)
        if case .note(let first) = notes[0].type {
            XCTAssertEqual(notes[0].beatPosition, 0)
            XCTAssertEqual(first.pitch, 60)
            XCTAssertEqual(first.duration, 1, accuracy: 0.00001)
            XCTAssertEqual(first.releaseVelocity, 42)
        } else { XCTFail("Missing first note") }
        if case .note(let second) = notes[1].type {
            XCTAssertEqual(notes[1].beatPosition, 0.25)
            XCTAssertEqual(second.pitch, 64)
            XCTAssertEqual(second.duration, 0.75, accuracy: 0.00001)
            XCTAssertEqual(second.releaseVelocity, 35)
        } else { XCTFail("Missing second note") }
    }

    func testImportPerformanceExportKeepsKeyswitchAsOrdinaryMIDINote() throws {
        let note = MIDIEvent.note(at: 0, pitch: 67, duration: 1)
        var midi = MIDIClipData(events: [note])
        midi.articulations = [
            StudioNoteArticulation(noteID: note.id, articulationID: "pizz")
        ]
        var track = Track(name: "Vln", type: .instrument)
        track.articulationMap = StudioArticulationMap(articulations: [
            StudioArticulationDefinition(id: "pizz", name: "Pizzicato",
                actions: [StudioArticulationAction(
                    kind: .keyswitch, number: 24, channel: 0)])
        ])
        track.clips = [Clip(name: "Vln", timeRange: TimeRange(
            start: TimePosition(beats: 0, tempo: 120),
            duration: TimePosition(beats: 2, tempo: 120)),
            content: .midi(midi))]
        var project = Project()
        project.tracks = [track]
        let file = try StandardMIDIFileExporter.encode(
            project: project, mode: .renderedPerformance)
        let imported = try StandardMIDIFileImporter.decode(file)
        XCTAssertEqual(imported.tracks.count, 1)
        let importedPitches = events(imported).compactMap { event -> UInt8? in
            if case .note(let note) = event.type { return note.pitch }
            return nil
        }
        XCTAssertEqual(Set(importedPitches), Set([UInt8(24), UInt8(67)]))
        // SMF does not embed Studio's semantic per-note articulation IDs.
        if case .midi(let clip) = imported.tracks[0].clips[0].content {
            XCTAssertNil(clip.articulations)
        } else { XCTFail("Expected imported MIDI clip") }
        XCTAssertEqual(midi.articulations?.first?.articulationID, "pizz")
    }

    func testRejectsTruncatedMIDIUnclosedNotesSMPTEAndF7Continuations() throws {
        let base = formatZero([
            0, 0x90, 60, 100,
            0x83, 0x60, 0x80, 60, 0,
            0, 0xFF, 0x2F, 0
        ])
        XCTAssertThrowsError(try StandardMIDIFileImporter.decode(Data(base.dropLast())))
        XCTAssertThrowsError(try StandardMIDIFileImporter.decode(formatZero([
            0, 0x90, 60, 100, 0, 0xFF, 0x2F, 0
        ])))
        XCTAssertThrowsError(try StandardMIDIFileImporter.decode(formatZero([
            0, 0xFF, 0x2F, 0
        ], division: 0xE728)))
        XCTAssertThrowsError(try StandardMIDIFileImporter.decode(formatZero([
            0, 0xF7, 1, 0x7F, 0, 0xFF, 0x2F, 0
        ])))
    }

    func testAtomicExportAndFailedImportDoNotDamageExistingFile() async throws {
        let manager = ProjectFileManager()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-midi-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Score.mid")
        let project = Project(name: "Empty")
        try await manager.export(project: project, to: url, format: .midi)
        let validBytes = try Data(contentsOf: url)
        XCTAssertEqual((try await manager.importMIDI(from: url)).name, "Score")
        let broken = folder.appendingPathComponent("broken.mid")
        try Data([0, 1, 2, 3]).write(to: broken)
        do {
            _ = try await manager.importMIDI(from: broken)
            XCTFail("Broken SMF must not import")
        } catch {
            XCTAssertEqual(try Data(contentsOf: url), validBytes)
        }
    }
}
