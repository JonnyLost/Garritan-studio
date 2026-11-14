import XCTest
@testable import DAWCore

final class DAWCoreTests: XCTestCase {
    
    // MARK: - Time Position Tests
    
    func testTimePositionConversion() {
        let position = TimePosition(beats: 4, tempo: 120, sampleRate: 44100)
        
        // 4 beats at 120 BPM = 2 seconds
        XCTAssertEqual(position.seconds, 2.0, accuracy: 0.001)
        
        // Verify sample count
        XCTAssertEqual(position.samples, 88200)
    }
    
    func testTimePositionFormatting() {
        let position = TimePosition(beats: 5.5, tempo: 120, sampleRate: 44100)
        let formatted = position.formatted(atTempo: 120, timeSignature: .common)
        
        // 5.5 beats = bar 2, beat 2 (0-indexed internally becomes 1-indexed in display)
        XCTAssertTrue(formatted.contains("2."))
    }
    
    func testTimeRangeOverlap() {
        let range1 = TimeRange(
            start: TimePosition(beats: 0, tempo: 120),
            duration: TimePosition(beats: 4, tempo: 120)
        )
        
        let range2 = TimeRange(
            start: TimePosition(beats: 2, tempo: 120),
            duration: TimePosition(beats: 4, tempo: 120)
        )
        
        let range3 = TimeRange(
            start: TimePosition(beats: 5, tempo: 120),
            duration: TimePosition(beats: 2, tempo: 120)
        )
        
        XCTAssertTrue(range1.overlaps(range2))
        XCTAssertFalse(range1.overlaps(range3))
    }
    
    // MARK: - Track Tests
    
    func testTrackCreation() {
        let track = Track(name: "Test Track", type: .midi, color: .blue)
        
        XCTAssertEqual(track.name, "Test Track")
        XCTAssertEqual(track.type, .midi)
        XCTAssertFalse(track.isMuted)
        XCTAssertFalse(track.isSolo)
        XCTAssertEqual(track.clips.count, 0)
    }
    
    func testTrackVolumeConversion() {
        var track = Track(name: "Test", type: .audio)
        
        // Set to -6 dB
        track.volumeDB = -6.0
        
        // Linear should be approximately 0.5
        XCTAssertEqual(track.volume, 0.501, accuracy: 0.01)
        
        // Verify round-trip
        XCTAssertEqual(track.volumeDB, -6.0, accuracy: 0.1)
    }
    
    func testTrackMIDIChannelFilter() {
        var track = Track(name: "MIDI Filter", type: .instrument)

        // All channels is the default and accepts the full MIDI 1.0 range.
        XCTAssertNil(track.midiOutputChannel)
        XCTAssertTrue(track.acceptsMIDIChannel(0))
        XCTAssertTrue(track.acceptsMIDIChannel(15))

        // Selection is zero-based: 0 = displayed channel 1.
        track.midiOutputChannel = 0
        XCTAssertTrue(track.acceptsMIDIChannel(0))
        XCTAssertFalse(track.acceptsMIDIChannel(1))
        XCTAssertFalse(track.acceptsMIDIChannel(15))

        track.midiOutputChannel = 15
        XCTAssertTrue(track.acceptsMIDIChannel(15))
        XCTAssertFalse(track.acceptsMIDIChannel(0))

        track.midiOutputChannel = nil
        XCTAssertTrue(track.acceptsMIDIChannel(8))
    }

    func testMIDIPlaybackWindowSeparatesSeekPastDueAndFuture() {
        let window = MIDIPlaybackWindow(sessionStartBeat: 12, bufferEndBeat: 12.5)

        // A seek should not retrigger notes that began in earlier measures.
        XCTAssertEqual(window.disposition(for: 11.999), .beforeSession)
        // Events exactly at the seek boundary are eligible.
        XCTAssertEqual(window.disposition(for: 12), .due)
        XCTAssertEqual(window.disposition(for: 12.25), .due)
        // Buffer end is exclusive, so the following callback owns the event.
        XCTAssertEqual(window.disposition(for: 12.5), .future)
    }

    func testMIDIPlaybackWindowProcessesOverdueEvents() {
        let window = MIDIPlaybackWindow(sessionStartBeat: 4, bufferEndBeat: 8)
        // A delayed worker still delivers unprocessed events before the end.
        XCTAssertEqual(window.disposition(for: 4.01), .due)
        XCTAssertEqual(window.disposition(for: 6), .due)
        XCTAssertEqual(window.disposition(for: 8), .future)
    }

    // MARK: - MIDI Event Tests
    
    func testMIDINoteCreation() {
        let note = MIDIEvent.note(at: 1.0, pitch: 60, velocity: 100, duration: 0.5)
        
        XCTAssertEqual(note.beatPosition, 1.0)
        
        if case .note(let data) = note.type {
            XCTAssertEqual(data.pitch, 60)
            XCTAssertEqual(data.velocity, 100)
            XCTAssertEqual(data.duration, 0.5)
            XCTAssertEqual(data.noteName, "C4")
        } else {
            XCTFail("Expected note event")
        }
    }
    
    func testMIDIReleaseVelocityAndSoftNoteOnRemainDistinct() {
        // Note Off is represented by zero velocity in the incoming MIDI model.
        XCTAssertEqual(NoteData(pitch: 60, velocity: 0).velocity, 0)
        // Velocity one is still a valid Note On, not a Note Off.
        XCTAssertEqual(NoteData(pitch: 60, velocity: 1).velocity, 1)
    }

    func testMIDINoteNameParsing() {
        XCTAssertEqual(NoteData.pitch(from: "C4"), 60)
        XCTAssertEqual(NoteData.pitch(from: "A4"), 69)
        XCTAssertEqual(NoteData.pitch(from: "C-1"), 0)
        XCTAssertEqual(NoteData.pitch(from: "G9"), 127)
    }
    
    func testMIDIScale() {
        let cMajor = MIDIScale.major
        
        // C4 (60) in C major
        XCTAssertTrue(cMajor.contains(pitch: 60, root: 60))  // C
        XCTAssertTrue(cMajor.contains(pitch: 64, root: 60))  // E
        XCTAssertTrue(cMajor.contains(pitch: 67, root: 60))  // G
        XCTAssertFalse(cMajor.contains(pitch: 61, root: 60)) // C#
    }
    
    // MARK: - Project Tests
    
    func testProjectCreation() {
        let project = ProjectFactory.createNewProject(name: "Test Project")
        
        XCTAssertEqual(project.name, "Test Project")
        XCTAssertEqual(project.tempo.bpm, 120)
        XCTAssertEqual(project.timeSignature, .common)
        // New projects start with one ready-to-load instrument track.
        XCTAssertEqual(project.tracks.count, 1)
        XCTAssertEqual(project.tracks.first?.type, .instrument)
    }
    
    func testDeletedTrackUndoPreservesInstrumentAndInsertPresets() {
        var project = Project(name: "Undo Preset")
        var track = Track(name: "ARIA Strings", type: .instrument)
        var instrument = PluginSlot()
        instrument.stateData = Data([0x10, 0x20, 0x30])
        var effect = PluginSlot()
        effect.stateData = Data([0xAA, 0xBB])
        track.instrumentSlot = instrument
        track.pluginSlots = [effect]
        project.tracks.append(track)

        let action = RemoveTrackAction(from: project, trackID: track.id)
        action.perform(on: &project)
        XCTAssertFalse(project.tracks.contains { $0.id == track.id })

        action.undo(on: &project)
        let restored = project.tracks.first { $0.id == track.id }
        XCTAssertEqual(restored?.instrumentSlot?.stateData, Data([0x10, 0x20, 0x30]))
        XCTAssertEqual(restored?.pluginSlots.first?.stateData, Data([0xAA, 0xBB]))
    }

    func testProjectTrackManagement() {
        var project = Project(name: "Test")
        
        let track1 = Track(name: "Track 1", type: .audio)
        let track2 = Track(name: "Track 2", type: .midi)
        
        project.addTrack(track1)
        project.addTrack(track2)
        
        XCTAssertEqual(project.tracks.count, 2)
        
        project.removeTrack(id: track1.id)
        XCTAssertEqual(project.tracks.count, 1)
        XCTAssertEqual(project.tracks.first?.id, track2.id)
    }
    
    // MARK: - Automation Tests
    
    func testAutomationInterpolation() {
        var lane = AutomationLane(parameter: .volume)
        
        lane.setPoint(at: 0, value: 0.0)
        lane.setPoint(at: 4, value: 1.0)
        
        // Test linear interpolation
        XCTAssertEqual(lane.value(atBeat: 0), 0.0, accuracy: 0.001)
        XCTAssertEqual(lane.value(atBeat: 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(lane.value(atBeat: 4), 1.0, accuracy: 0.001)
    }
    
    // MARK: - Clip Tests
    
    func testMIDIClipData() {
        var midiData = MIDIClipData()
        
        midiData.events = [
            .note(at: 0, pitch: 60, velocity: 100, duration: 0.5),
            .note(at: 0.5, pitch: 62, velocity: 90, duration: 0.5),
            .note(at: 1, pitch: 64, velocity: 80, duration: 1.0),
        ]
        
        XCTAssertEqual(midiData.noteEvents.count, 3)
        XCTAssertEqual(midiData.sortedEvents.first?.beatPosition, 0)
    }
    
    // MARK: - Quantization Tests
    
    func testQuantization() {
        let beat = 1.7
        
        let quantizedNearest = TimeUtilities.quantize(beats: beat, gridDivision: 0.5, mode: .nearest)
        XCTAssertEqual(quantizedNearest, 1.5, accuracy: 0.001)
        
        let quantizedFloor = TimeUtilities.quantize(beats: beat, gridDivision: 0.5, mode: .floor)
        XCTAssertEqual(quantizedFloor, 1.5, accuracy: 0.001)
        
        let quantizedCeil = TimeUtilities.quantize(beats: beat, gridDivision: 0.5, mode: .ceil)
        XCTAssertEqual(quantizedCeil, 2.0, accuracy: 0.001)
    }
}

@available(macOS 14.0, *)
final class ProjectPersistenceSafetyTests: XCTestCase {
    func testFailedFullSavePreservesPreviouslySavedProject() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarritanPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let package = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        var project = Project(name: "Original")
        try await manager.save(project: project, to: package)

        project.name = "Edited"
        project.audioFiles.append(AudioFileReference(
            originalPath: folder.appendingPathComponent("missing.wav").path,
            relativePath: "",
            sampleRate: 44100,
            channelCount: 2,
            lengthInSamples: 100,
            bitDepth: 24
        ))

        var saveFailed = false
        do {
            try await manager.save(project: project, to: package)
        } catch {
            saveFailed = true
        }
        XCTAssertTrue(saveFailed, "Saving with missing audio must fail")
        let recovered = try await manager.load(from: package)
        XCTAssertEqual(recovered.name, "Original")
        XCTAssertTrue(recovered.audioFiles.isEmpty)
    }

    func testQuickSaveDoesNotOverwritePreviousProjectIfAudioIsMissing() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarritanQuickSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        try await manager.save(project: Project(name: "Good Save"), to: package)

        var edited = Project(name: "Incomplete Save")
        edited.audioFiles.append(AudioFileReference(
            originalPath: folder.appendingPathComponent("unrecorded.wav").path,
            relativePath: "",
            sampleRate: 44100,
            channelCount: 2,
            lengthInSamples: 100,
            bitDepth: 24
        ))
        do {
            try await manager.saveQuick(project: edited, to: package)
            XCTFail("Quick Save must reject missing audio")
        } catch {
            // Expected: no replacement of the previous complete project.
        }
        let preserved = try await manager.load(from: package)
        XCTAssertEqual(preserved.name, "Good Save")
        XCTAssertTrue(preserved.audioFiles.isEmpty)
    }

    func testProjectPackageDirectoryCannotMasqueradeAsAudioFile() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarritanAudioDirectory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        try await manager.save(project: Project(name: "Before"), to: package)

        var edited = Project(name: "After")
        edited.audioFiles.append(AudioFileReference(
            originalPath: package.path,
            relativePath: "",
            sampleRate: 44100,
            channelCount: 2,
            lengthInSamples: 500,
            bitDepth: 24
        ))
        do {
            try await manager.save(project: edited, to: package)
            XCTFail("The package directory is not a valid audio source")
        } catch {
            // Expected: audio sources must be regular files.
        }
        let preserved = try await manager.load(from: package)
        XCTAssertEqual(preserved.name, "Before")
        XCTAssertTrue(preserved.audioFiles.isEmpty)
    }

    func testDefaultMIDIExportWritesValidConductorEvenForEmptyProject() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarritanExport-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: destination) }

        let manager = ProjectFileManager()
        try await manager.export(project: Project(name: "Test"),
                                 to: destination, format: .midi)
        let bytes = Array(try Data(contentsOf: destination))
        XCTAssertGreaterThan(bytes.count, 22)
        XCTAssertEqual(Array(bytes.prefix(4)), Array("MThd".utf8))
        XCTAssertEqual(Array(bytes[8..<10]), [0x00, 0x01]) // Format 1
        XCTAssertEqual(Array(bytes[10..<12]), [0x00, 0x01]) // Conductor track
        XCTAssertEqual(Array(bytes[12..<14]), [0x01, 0xE0]) // 480 PPQ
        XCTAssertEqual(Array(bytes[14..<18]), Array("MTrk".utf8))
    }

    func testFullSavePreservesAudioAlreadyInsideProjectPackage() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarritanPackagedAudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let source = folder.appendingPathComponent("sample.wav")
        let sampleBytes = Data([0x52, 0x49, 0x46, 0x46])
        try sampleBytes.write(to: source)

        let package = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        var project = Project(name: "First Save")
        project.audioFiles.append(AudioFileReference(
            originalPath: source.path,
            relativePath: "",
            sampleRate: 44100,
            channelCount: 2,
            lengthInSamples: 2,
            bitDepth: 24
        ))
        try await manager.save(project: project, to: package)
        try FileManager.default.removeItem(at: source)

        var loaded = try await manager.load(from: package)
        loaded.name = "Second Save"
        try await manager.save(project: loaded, to: package)

        let recovered = try await manager.load(from: package)
        XCTAssertEqual(recovered.name, "Second Save")
        let packagedAudio = URL(fileURLWithPath: try XCTUnwrap(recovered.audioFiles.first).originalPath)
        XCTAssertEqual(try Data(contentsOf: packagedAudio), sampleBytes)
    }
}
