import Foundation
import XCTest
@testable import DAWCore

final class StandardMIDIFileExporterTests: XCTestCase {
    private func bodyChunks(_ data: Data) throws -> [[UInt8]] {
        let bytes = Array(data)
        guard bytes.count >= 14, Array(bytes.prefix(4)) == Array("MThd".utf8) else {
            throw PersistenceError.invalidFormat("Missing MIDI header")
        }
        let count = Int(bytes[10]) * 256 + Int(bytes[11])
        var offset = 14
        var bodies: [[UInt8]] = []
        for _ in 0..<count {
            guard offset + 8 <= bytes.count,
                  Array(bytes[offset..<(offset + 4)]) == Array("MTrk".utf8) else {
                throw PersistenceError.invalidFormat("Missing MIDI track chunk")
            }
            let length = bytes[(offset + 4)..<(offset + 8)]
                .reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 8 else {
                throw PersistenceError.invalidFormat("MIDI track length exceeds data")
            }
            bodies.append(Array(bytes[(offset + 8)..<(offset + 8 + length)]))
            offset += 8 + length
        }
        XCTAssertEqual(offset, bytes.count, "No trailing non-track bytes")
        return bodies
    }

    private func contains(_ sequence: [UInt8], in bytes: [UInt8]) -> Bool {
        guard !sequence.isEmpty, bytes.count >= sequence.count else { return false }
        return (0...(bytes.count - sequence.count)).contains {
            Array(bytes[$0..<($0 + sequence.count)]) == sequence
        }
    }

    private func makeClip(start: Double = 2, length: Double = 4,
                          events: [MIDIEvent]) -> Clip {
        Clip(name: "Phrase",
             timeRange: TimeRange(
                start: TimePosition(beats: start, tempo: 120),
                duration: TimePosition(beats: length, tempo: 120)
             ),
             content: .midi(MIDIClipData(events: events)))
    }

    func testMultitrackExportHasConductorTempoAndSeparateNamedMusicTracks() throws {
        var project = Project(name: "Orchestra")
        project.tempo = Tempo(bpm: 120)
        project.timeSignature = .common
        var strings = Track(name: "Violins", type: .instrument)
        strings.clips = [makeClip(events: [.note(at: 0, pitch: 60, velocity: 100, duration: 1)])]
        var winds = Track(name: "Winds", type: .midi)
        winds.clips = [makeClip(events: [.note(at: 1, pitch: 67, velocity: 90, duration: 0.5)])]
        project.tracks = [strings, winds]

        let data = try StandardMIDIFileExporter.encode(project: project)
        let header = Array(data.prefix(14))
        XCTAssertEqual(Array(header[8..<10]), [0x00, 0x01])
        XCTAssertEqual(Array(header[10..<12]), [0x00, 0x03])
        XCTAssertEqual(Array(header[12..<14]), [0x01, 0xE0]) // 480 PPQ

        let chunks = try bodyChunks(data)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(contains([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20], in: chunks[0]))
        XCTAssertTrue(contains([0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08], in: chunks[0]))
        XCTAssertTrue(contains(Array("Violins".utf8), in: chunks[1]))
        XCTAssertTrue(contains(Array("Winds".utf8), in: chunks[2]))
        XCTAssertTrue(contains([0x87, 0x40, 0x90, 60, 100], in: chunks[1]))
        XCTAssertTrue(contains([0x83, 0x60, 0x80, 60, 0], in: chunks[1]))
        XCTAssertTrue(contains([0xFF, 0x2F, 0], in: chunks[2]))
    }

    func testControllerPitchBendProgramAndNoteOffAreSerialized() throws {
        var project = Project(name: "Controllers")
        var track = Track(name: "Expression", type: .instrument)
        track.clips = [makeClip(start: 0, length: 4, events: [
            .note(at: 0, pitch: 60, velocity: 1, duration: 0.5),
            .controlChange(at: 1, controller: 11, value: 96),
            .pitchBend(at: 1.5, value: 0),
            MIDIEvent(beatPosition: 2, type: .programChange(program: 42)),
            MIDIEvent(beatPosition: 2.5, type: .aftertouch(pressure: 80)),
            MIDIEvent(beatPosition: 3, type: .polyAftertouch(note: 60, pressure: 50))
        ])]
        project.tracks = [track]
        let chunks = try bodyChunks(StandardMIDIFileExporter.encode(project: project))
        let music = chunks[1]
        XCTAssertTrue(contains([0x90, 60, 1], in: music),
                      "Velocity 1 is a valid Note On")
        XCTAssertTrue(contains([0x80, 60, 0], in: music))
        XCTAssertTrue(contains([0xB0, 11, 96], in: music))
        XCTAssertTrue(contains([0xE0, 0, 64], in: music)) // Center bend
        XCTAssertTrue(contains([0xC0, 42], in: music))
        XCTAssertTrue(contains([0xD0, 80], in: music))
        XCTAssertTrue(contains([0xA0, 60, 50], in: music))
    }

    func testTempoAndMeterChangesAreInGlobalConductor() throws {
        var project = Project(name: "Changes")
        project.tempoChanges = [TempoChange(beatPosition: 4, tempo: Tempo(bpm: 90))]
        project.timeSignatureChanges = [
            TimeSignatureChange(beatPosition: 8,
                                timeSignature: TimeSignature(numerator: 3, denominator: 4))
        ]
        let conductor = try bodyChunks(StandardMIDIFileExporter.encode(project: project))[0]
        XCTAssertTrue(contains([0xFF, 0x51, 0x03, 0x0A, 0x2C, 0x2B], in: conductor))
        XCTAssertTrue(contains([0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08], in: conductor))
    }

    func testMutedTracksAndMIDIChannelFilterAreHonored() throws {
        var project = Project()
        var track = Track(name: "Selected", type: .instrument)
        track.midiOutputChannel = 0
        track.clips = [makeClip(start: 0, events: [
            .note(at: 0, pitch: 60, channel: 0),
            .note(at: 1, pitch: 61, channel: 1)
        ])]
        var muted = Track(name: "Muted", type: .midi)
        muted.isMuted = true
        muted.clips = [makeClip(events: [.note(at: 0, pitch: 70)])]
        project.tracks = [track, muted]
        let chunks = try bodyChunks(StandardMIDIFileExporter.encode(project: project))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(contains([0x90, 60, 100], in: chunks[1]))
        XCTAssertFalse(contains([0x91, 61, 100], in: chunks[1]))
        XCTAssertFalse(contains([0x90, 70, 100], in: chunks[1]))
    }

    func testUnsafeOrUnrepresentableTimingFailsBeforeWriting() async throws {
        var project = Project()
        var track = Track(name: "Invalid", type: .instrument)
        track.clips = [makeClip(events: [.note(at: .nan, pitch: 60)])]
        project.tracks = [track]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioBadMIDI-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = Data([0xAA, 0xBB, 0xCC])
        try existing.write(to: url)
        let manager = ProjectFileManager()
        do {
            try await manager.export(project: project, to: url, format: .midi)
            XCTFail("NaN events must not be exported")
        } catch {
            XCTAssertEqual(try Data(contentsOf: url), existing,
                           "Validation failures must not destroy previous exports")
        }
    }

    func testTempoRampsAndUnexpandedLoopsFailClearly() throws {
        var project = Project()
        project.tempoChanges = [
            TempoChange(beatPosition: 4, tempo: Tempo(bpm: 90), curveType: .linear)
        ]
        XCTAssertThrowsError(try StandardMIDIFileExporter.encode(project: project))
        project.tempoChanges = []

        var track = Track(name: "Loop", type: .midi)
        var clip = makeClip(events: [.note(at: 0, pitch: 60)])
        clip.isLooped = true
        track.clips = [clip]
        project.tracks = [track]
        XCTAssertThrowsError(try StandardMIDIFileExporter.encode(project: project))
    }
}
