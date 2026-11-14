import XCTest
@testable import DAWCore

final class OstinatoPatternTests: XCTestCase {
    func testRhythmicAndMelodicStartersHaveEditableNotes() {
        let rhythm = OstinatoPattern.starter(mode: .rhythmic)
        let melody = OstinatoPattern.starter(mode: .melodic)
        XCTAssertEqual(rhythm.mode, .rhythmic)
        XCTAssertEqual(melody.mode, .melodic)
        XCTAssertEqual(rhythm.lanes.count, 3)
        XCTAssertEqual(melody.lanes.count, 3)
        XCTAssertEqual(rhythm.stepCount, 16)
        XCTAssertFalse(rhythm.midiEvents().isEmpty)
        XCTAssertFalse(melody.midiEvents().isEmpty)
    }

    func testStepToggleChangesOnlyIntendedCell() {
        var lane = OstinatoLane(name: "Violas", pitch: 60)
        lane.toggleStep(at: 3)
        XCTAssertEqual(lane.steps.map(\.index), [3])
        lane.toggleStep(at: 4)
        lane.toggleStep(at: 3)
        XCTAssertEqual(lane.steps.map(\.index), [4])
        XCTAssertEqual(lane.steps.first?.pitch, 60)
    }

    func testPitchChangeRetunesExistingSteps() {
        var lane = OstinatoLane(name: "Strings", pitch: 60, steps: [
            OstinatoStep(index: 0, pitch: 60),
            OstinatoStep(index: 4, pitch: 60)
        ])
        lane.changePitch(to: 67)
        XCTAssertEqual(lane.pitch, 67)
        XCTAssertEqual(lane.steps.map(\.pitch), [67, 67])
    }

    func testRendererUsesBeatRelativeStepsAndKeepsNotesWithinClip() throws {
        let pattern = OstinatoPattern(
            name: "Pulse",
            mode: .melodic,
            bars: 2,
            beatsPerBar: 4,
            stepsPerBeat: 4,
            lanes: [
                OstinatoLane(name: "Cello", pitch: 48, steps: [
                    OstinatoStep(index: 0, pitch: 48, velocity: 92),
                    OstinatoStep(index: 15, pitch: 48, velocity: 110),
                    OstinatoStep(index: 31, pitch: 48)
                ])
            ]
        )
        XCTAssertEqual(pattern.durationInBeats, 8, accuracy: 0.001)
        let events = pattern.midiEvents()
        XCTAssertEqual(events.map(\.beatPosition), [0, 3.75, 7.75])
        let clip = try XCTUnwrap(OstinatoRenderer.makeClip(
            pattern: pattern, atBeat: 12, tempo: 120, sampleRate: 44100
        ))
        XCTAssertEqual(clip.timeRange.start.samples, 264600)
        XCTAssertEqual(clip.timeRange.duration.samples, 176400)
        if case .midi(let midi) = clip.content {
            XCTAssertEqual(midi.events.count, 3)
            XCTAssertEqual(midi.originalTempo, 120)
            XCTAssertEqual(midi.events.map(\.beatPosition), [0, 3.75, 7.75])
        } else {
            XCTFail("Expected an editable MIDI clip")
        }
    }

    func testInvalidOrDuplicateStepsAreNotRendered() {
        let pattern = OstinatoPattern(
            name: "Bounds",
            mode: .rhythmic,
            lanes: [
                OstinatoLane(name: "Drum", pitch: 36, steps: [
                    OstinatoStep(index: -1, pitch: 36),
                    OstinatoStep(index: 0, pitch: 36),
                    OstinatoStep(index: 0, pitch: 36),
                    OstinatoStep(index: 16, pitch: 36)
                ])
            ]
        )
        XCTAssertEqual(pattern.midiEvents().count, 1)
        XCTAssertNil(OstinatoRenderer.makeClip(
            pattern: OstinatoPattern(name: "Empty", mode: .rhythmic),
            atBeat: 0, tempo: 120, sampleRate: 44100
        ))
        XCTAssertNil(OstinatoRenderer.makeClip(
            pattern: pattern, atBeat: -.infinity, tempo: 120, sampleRate: 44100
        ))
    }

    func testCompoundMeterAndGridLength() {
        let sixEight = OstinatoPattern(name: "6/8", mode: .rhythmic,
                                     bars: 2, beatsPerBar: 3, stepsPerBeat: 4)
        XCTAssertEqual(sixEight.stepCount, 24)
        XCTAssertEqual(sixEight.durationInBeats, 6)
        let fiveEight = OstinatoPattern(name: "5/8", mode: .melodic,
                                      bars: 3, beatsPerBar: 2.5, stepsPerBeat: 4)
        XCTAssertEqual(fiveEight.stepCount, 30)
        XCTAssertEqual(fiveEight.durationInBeats, 7.5)
    }

    func testPatternsSurviveProjectJSONRoundTrip() throws {
        var project = Project(name: "Ostinato Test")
        var pattern = OstinatoPattern.starter(mode: .melodic)
        pattern.name = "Build"
        project.ostinatoPatterns = [pattern]
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        XCTAssertEqual(decoded.ostinatoPatterns?.first?.id, pattern.id)
        XCTAssertEqual(decoded.ostinatoPatterns?.first?.name, "Build")
        XCTAssertEqual(decoded.ostinatoPatterns?.first?.midiEvents().count,
                       pattern.midiEvents().count)
    }

    func testOlderProjectWithoutPatternsStillDecodes() throws {
        let project = Project(name: "Existing Session")
        let encoded = try JSONEncoder().encode(project)
        var dictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        dictionary.removeValue(forKey: "ostinatoPatterns")
        let legacyData = try JSONSerialization.data(withJSONObject: dictionary)
        let decoded = try JSONDecoder().decode(Project.self, from: legacyData)
        XCTAssertEqual(decoded.name, "Existing Session")
        XCTAssertTrue((decoded.ostinatoPatterns ?? []).isEmpty)
    }
    func testAuditionNotesHaveFinitePositiveDurationsWithinPattern() {
        let pattern = OstinatoPattern.starter(mode: .melodic, beatsPerBar: 3)
        let notes = pattern.midiEvents()
        XCTAssertFalse(notes.isEmpty)
        for event in notes {
            guard case .note(let data) = event.type else {
                return XCTFail("Audition should render ordinary MIDI notes")
            }
            XCTAssertTrue(event.beatPosition.isFinite)
            XCTAssertGreaterThan(data.duration, 0)
            XCTAssertLessThanOrEqual(event.beatPosition + data.duration,
                                     pattern.durationInBeats + 0.000001)
        }
    }

    func testPreviewRenderingDoesNotMutateSavedPattern() throws {
        let original = OstinatoPattern.starter(mode: .rhythmic)
        let before = try JSONEncoder().encode(original)
        _ = original.midiEvents()
        _ = original.midiEvents()
        XCTAssertEqual(try JSONEncoder().encode(original), before)
    }

}
