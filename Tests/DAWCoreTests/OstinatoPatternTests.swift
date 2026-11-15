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
        // Dictionary encoding order is not stable without sortedKeys, even when
        // the value has not changed. Compare canonical JSON instead.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(original)
        _ = original.midiEvents()
        _ = original.midiEvents()
        XCTAssertEqual(try encoder.encode(original), before)
    }

    func testSoloAndMuteDetermineRoutedOrchestralLanes() {
        let strings = TrackID()
        let brass = TrackID()
        var pattern = OstinatoPattern.starter(mode: .melodic)
        pattern.lanes[0].targetTrackID = strings
        pattern.lanes[1].targetTrackID = brass
        pattern.lanes[0].isSolo = true
        XCTAssertEqual(pattern.routedMIDIEvents().count, 1)
        XCTAssertEqual(pattern.routedMIDIEvents().first?.lane.targetTrackID, strings)
        pattern.lanes[0].isMuted = true
        XCTAssertTrue(pattern.midiEvents().isEmpty)
    }

    func testOrchestralRoutingSurvivesProjectPatternSerialization() throws {
        var pattern = OstinatoPattern.starter(mode: .rhythmic)
        let destination = TrackID()
        pattern.lanes[0].targetTrackID = destination
        pattern.lanes[0].isMuted = true
        pattern.lanes[1].isSolo = true
        let decoded = try JSONDecoder().decode(OstinatoPattern.self,
            from: JSONEncoder().encode(pattern))
        XCTAssertEqual(decoded.lanes[0].targetTrackID, destination)
        XCTAssertEqual(decoded.lanes[0].isMuted, true)
        XCTAssertEqual(decoded.lanes[1].isSolo, true)
    }

    func testVariationsPreserveOriginalAndOrchestralRouting() throws {
        var original = OstinatoPattern.starter(mode: .melodic)
        let track = TrackID()
        original.lanes[0].targetTrackID = track
        original.lanes[1].isMuted = true
        let snapshot = try JSONEncoder().encode(original)
        for kind in OstinatoVariation.allCases {
            let variation = OstinatoVariationEngine.makeVariation(of: original, kind: kind)
            XCTAssertNotEqual(variation.id, original.id)
            XCTAssertEqual(variation.lanes[0].targetTrackID, track)
            XCTAssertEqual(variation.lanes[1].isMuted, true)
            XCTAssertEqual(variation.stepCount, original.stepCount)
            XCTAssertTrue(variation.lanes.allSatisfy { lane in
                lane.steps.allSatisfy { $0.index >= 0 && $0.index < variation.stepCount }
            })
        }
        XCTAssertEqual(try JSONEncoder().encode(original), snapshot)
    }

    func testSeededVariationsAreReproducible() {
        let source = OstinatoPattern.starter(mode: .rhythmic)
        for kind in [OstinatoVariation.sparse, .dense] {
            let first = OstinatoVariationEngine.makeVariation(of: source, kind: kind, seed: 42)
            let second = OstinatoVariationEngine.makeVariation(of: source, kind: kind, seed: 42)
            XCTAssertEqual(first.lanes.map { $0.steps }, second.lanes.map { $0.steps })
        }
    }

    func testVariationOctavesClampToMIDIAndReverseStaysOnGrid() {
        var source = OstinatoPattern.starter(mode: .melodic)
        source.lanes[0].changePitch(to: 125)
        let raised = OstinatoVariationEngine.makeVariation(of: source, kind: .octaveUp)
        XCTAssertEqual(raised.lanes[0].pitch, 127)
        let reversed = OstinatoVariationEngine.makeVariation(of: source, kind: .reverse)
        XCTAssertEqual(reversed.lanes[0].steps.first?.index,
                       source.stepCount - 1 - (source.lanes[0].steps.last?.index ?? 0))
    }

    func testEvolutionProducesBoundedEditableRepetitions() {
        let source = OstinatoPattern.starter(mode: .melodic)
        for shape in OstinatoEvolutionShape.allCases {
            let result = OstinatoEvolutionEngine.sequence(
                from: source, repetitions: 8, shape: shape, seed: 25)
            XCTAssertEqual(result.count, 8)
            XCTAssertEqual(Set(result.map(\.id)).count, 8)
            XCTAssertTrue(result.allSatisfy { $0.stepCount == source.stepCount })
            XCTAssertTrue(result.allSatisfy { pattern in
                pattern.lanes.allSatisfy { lane in
                    lane.steps.allSatisfy { $0.index >= 0 && $0.index < pattern.stepCount }
                }
            })
        }
    }

    func testEvolutionIsDeterministicAndPreservesSourceRouting() {
        var source = OstinatoPattern.starter(mode: .rhythmic)
        let destination = TrackID()
        source.lanes[0].targetTrackID = destination
        let first = OstinatoEvolutionEngine.sequence(
            from: source, repetitions: 6, shape: .wave, seed: 99)
        let second = OstinatoEvolutionEngine.sequence(
            from: source, repetitions: 6, shape: .wave, seed: 99)
        XCTAssertEqual(first.map { $0.lanes.map(\.steps) },
                       second.map { $0.lanes.map(\.steps) })
        XCTAssertTrue(first.allSatisfy { $0.lanes[0].targetTrackID == destination })
        XCTAssertEqual(source.lanes[0].targetTrackID, destination)
        XCTAssertEqual(source.name, "New Rhythm")
    }

    func testResolvedRoutesRespectSoloAndExplicitDestinations() {
        let strings = TrackID()
        let brass = TrackID()
        var pattern = OstinatoPattern.starter(mode: .melodic)
        pattern.lanes[0].targetTrackID = strings
        pattern.lanes[1].targetTrackID = brass
        pattern.lanes[2].isMuted = true
        let routes = pattern.resolvedRoutes(validTracks: [strings, brass], fallback: nil)
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].track, strings)
        XCTAssertEqual(routes[1].track, brass)
        pattern.lanes[1].isSolo = true
        XCTAssertEqual(pattern.resolvedRoutes(validTracks: [strings, brass], fallback: nil).count, 1)
    }

    func testResolvedRoutesRejectMissingTracksWithoutFallback() {
        let missing = TrackID()
        let fallback = TrackID()
        var pattern = OstinatoPattern.starter(mode: .rhythmic)
        pattern.lanes[0].targetTrackID = missing
        XCTAssertTrue(pattern.resolvedRoutes(validTracks: [], fallback: fallback).isEmpty)
        XCTAssertEqual(pattern.resolvedRoutes(validTracks: [fallback], fallback: fallback).count, 3)
    }

}
