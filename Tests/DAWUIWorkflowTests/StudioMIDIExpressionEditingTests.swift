import XCTest
import DAWCore
@testable import DAWUI

final class StudioMIDIExpressionEditingTests: XCTestCase {
    func testStraightRampUsesEndpointsNotIntermediatePointerJitter() {
        let points = [
            StudioMIDIExpressionPoint(beat: 0, value: 0),
            StudioMIDIExpressionPoint(beat: 0.5, value: 1),
            StudioMIDIExpressionPoint(beat: 1, value: 0.8)
        ]
        let result = StudioMIDIExpressionEditing.draw(
            events: [], lane: .expression, points: points,
            clipStartBeat: 0, division: 0.25, mode: .line)
        let curve = result.sorted { $0.beatPosition < $1.beatPosition }
        XCTAssertEqual(curve.count, 5)
        XCTAssertEqual(curve[0].beatPosition, 0)
        XCTAssertEqual(curve[2].beatPosition, 0.5)
        XCTAssertEqual(curve[4].beatPosition, 1)
        if case .controlChange(_, let midpoint) = curve[2].type {
            XCTAssertEqual(midpoint, 51) // 0.4 of CC 0...127
        } else { XCTFail("Expected expression ramp") }
    }

    func testSmoothCurveEasesAtBothEndsAndPreservesBounds() {
        let points = [
            StudioMIDIExpressionPoint(beat: 0, value: 0),
            StudioMIDIExpressionPoint(beat: 2, value: 1)
        ]
        let result = StudioMIDIExpressionEditing.draw(
            events: [], lane: .modulation, points: points,
            clipStartBeat: 0, division: 0.25, mode: .curve)
        let sorted = result.sorted { $0.beatPosition < $1.beatPosition }
        XCTAssertEqual(sorted.count, 9)
        func value(at i: Int) -> UInt8 {
            if case .controlChange(_, let value) = sorted[i].type {
                return value
            }
            return 0
        }
        XCTAssertEqual(value(at: 0), 0)
        XCTAssertEqual(value(at: 8), 127)
        XCTAssertLessThan(value(at: 1), 16) // eased vs linear 16
        XCTAssertEqual(value(at: 4), 64)
        XCTAssertGreaterThan(value(at: 7), 111)
        XCTAssertTrue(sorted.allSatisfy {
            StudioMIDIExpressionEditing.normalizedValue(
                of: $0, for: .modulation) != nil
        })
    }

    func testEraserOnlyDeletesSelectedControllerAndChannelInSweep() {
        let cc1a = MIDIEvent.controlChange(at: 1, controller: 1, value: 30)
        let cc1b = MIDIEvent.controlChange(at: 1.5, controller: 1, value: 90)
        let cc1outside = MIDIEvent.controlChange(at: 3, controller: 1, value: 60)
        let otherChannel = MIDIEvent.controlChange(at: 1, controller: 1,
                                                   value: 70, channel: 1)
        let otherLane = MIDIEvent.controlChange(at: 1.5, controller: 11, value: 55)
        let note = MIDIEvent.note(at: 1.5, pitch: 62)
        let erased = StudioMIDIExpressionEditing.draw(
            events: [cc1a, cc1b, cc1outside, otherChannel, otherLane, note],
            lane: .modulation,
            points: [.init(beat: 1.5, value: 0.1), .init(beat: 1, value: 0.5)],
            clipStartBeat: 0, division: 0.25,
            channel: 0, mode: .erase)
        XCTAssertEqual(erased.count, 4)
        XCTAssertFalse(erased.contains { $0.id == cc1a.id })
        XCTAssertFalse(erased.contains { $0.id == cc1b.id })
        for keep in [cc1outside, otherChannel, otherLane, note] {
            XCTAssertTrue(erased.contains { $0.id == keep.id })
        }
    }

    func testSingleClickEraserHandlesUnsnappedEventInOffsetRegion() {
        let midi = MIDIEvent.controlChange(at: 0.375, controller: 11, value: 70)
        let a = StudioMIDIExpressionEditing.draw(
            events: [midi], lane: .expression,
            points: [.init(beat: 2.5, value: 0.5)],
            clipStartBeat: 2.125, division: 0.25, mode: .erase)
        XCTAssertTrue(a.isEmpty)
    }

    func testEraserNoMatchingEventMakesNoEdits() {
        let note = MIDIEvent.note(at: 0.5, pitch: 70)
        let result = StudioMIDIExpressionEditing.draw(
            events: [note], lane: .pitchBend,
            points: [.init(beat: 0.5, value: 0.2)],
            clipStartBeat: 0, division: 0.25, mode: .erase)
        XCTAssertEqual(result.map(\.id), [note.id])
    }

    func testCurveAndLineRetainOverwrittenEventID() {
        let point = MIDIEvent.controlChange(at: 0.5, controller: 11, value: 30)
        for mode in [StudioExpressionDrawMode.line, .curve] {
            let result = StudioMIDIExpressionEditing.draw(
                events: [point], lane: .expression,
                points: [.init(beat: 0, value: 0),
                         .init(beat: 1, value: 1)],
                clipStartBeat: 0, division: 0.25, mode: mode)
            XCTAssertEqual(result.first { $0.beatPosition == 0.5 }?.id, point.id)
        }
    }

    func testOffsetRegionRetainsEventIDWhenFirstGridCellIsFractional() {
        let existing = MIDIEvent.controlChange(at: 0, controller: 11, value: 44)
        let edited = StudioMIDIExpressionEditing.draw(
            events: [existing], lane: .expression,
            points: [.init(beat: 2.125, value: 0.75)],
            clipStartBeat: 2.125, division: 0.25, mode: .pencil)
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited[0].id, existing.id)
        XCTAssertEqual(edited[0].beatPosition, 0)
    }

    func testExpressionCurveCannotWriteEventsOutsideTrimmedRegion() {
        let result = StudioMIDIExpressionEditing.draw(
            events: [], lane: .modulation,
            points: [.init(beat: 3.75, value: 0.2),
                     .init(beat: 4.1, value: 0.9)],
            clipStartBeat: 2, division: 0.25, mode: .curve,
            clipEndBeat: 4.2)
        XCTAssertTrue(result.allSatisfy { $0.beatPosition + 2 < 4.2 })
        XCTAssertEqual(result.last?.beatPosition, 2)
    }

    func testDensePencilStrokeRespectsControllerEventBudget() {
        let stroke = (0..<2000).map { i in
            StudioMIDIExpressionPoint(beat: Double(i) * 0.25,
                                      value: Double(i % 7) / 6)
        }
        let events = StudioMIDIExpressionEditing.draw(
            events: [], lane: .expression, points: stroke,
            clipStartBeat: 0, division: 0.25, mode: .pencil)
        XCTAssertLessThanOrEqual(events.count, 4096)
    }

    func testCC1AndCC11AreIndependent() {
        let cc1 = MIDIEvent.controlChange(at: 1, controller: 1, value: 48)
        let cc11 = MIDIEvent.controlChange(at: 1.5, controller: 11, value: 83)
        let note = MIDIEvent.note(at: 1, pitch: 60, duration: 2)
        let result = StudioMIDIExpressionEditing.draw(
            events: [cc1, cc11, note], lane: .modulation,
            points: [.init(beat: 1, value: 0.8)],
            clipStartBeat: 0, division: 0.25)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.contains(where: { $0.id == cc11.id }))
        XCTAssertTrue(result.contains(where: { $0.id == note.id }))
        let matching = result.filter {
            StudioMIDIExpressionEditing.normalizedValue(of: $0, for: .modulation) != nil
        }
        XCTAssertEqual(matching.count, 1)
        if case .controlChange(let cc, let value) = matching[0].type {
            XCTAssertEqual(cc, 1)
            XCTAssertEqual(value, 102)
        } else { XCTFail("Expected CC1") }
    }

    func testPitchBendUsesNative14BitEventNotController128() {
        let low = StudioMIDIExpressionEditing.makeEvent(at: 1, lane: .pitchBend,
                                                        normalized: 0)
        let mid = StudioMIDIExpressionEditing.makeEvent(at: 1, lane: .pitchBend,
                                                        normalized: 0.5)
        let high = StudioMIDIExpressionEditing.makeEvent(at: 1, lane: .pitchBend,
                                                         normalized: 1)
        for (event, expected) in [(low, -8192), (mid, 0), (high, 8191)] {
            guard let event else { XCTFail("Missing pitch bend"); continue }
            if case .pitchBend(let value) = event.type {
                XCTAssertEqual(Int(value), expected)
            } else { XCTFail("Incorrect event type") }
        }
    }

    func testSustainIsDiscreteAndClamped() {
        let off = StudioMIDIExpressionEditing.makeEvent(at: 0, lane: .sustain,
                                                        normalized: -5)
        let on = StudioMIDIExpressionEditing.makeEvent(at: 0, lane: .sustain,
                                                       normalized: 3)
        if case .controlChange(let c0, let v0) = off!.type,
           case .controlChange(let c1, let v1) = on!.type {
            XCTAssertEqual(c0, 64)
            XCTAssertEqual(c1, 64)
            XCTAssertEqual(v0, 0)
            XCTAssertEqual(v1, 127)
        } else { XCTFail("Expected sustain controllers") }
    }

    func testDrawingInterpolatesAndOverwritesExistingLaneOncePerBeat() {
        let old = MIDIEvent.controlChange(at: 0.5, controller: 11, value: 70)
        let result = StudioMIDIExpressionEditing.draw(
            events: [old], lane: .expression,
            points: [.init(beat: 0, value: 0), .init(beat: 1, value: 1)],
            clipStartBeat: 0, division: 0.25)
        let points = result.filter {
            StudioMIDIExpressionEditing.normalizedValue(of: $0, for: .expression) != nil
        }
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(Set(points.map(\.beatPosition)).count, 5)
        XCTAssertEqual(points.first(where: { $0.beatPosition == 0.5 })?.id, old.id)
    }

    func testOffsetClipSnapsInProjectBeatTime() {
        let result = StudioMIDIExpressionEditing.draw(
            events: [], lane: .expression,
            points: [.init(beat: 2.625, value: 0.5)], clipStartBeat: 2.125,
            division: 0.25)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].beatPosition, 0.625)
    }

    func testCCAndPitchBendSurviveProjectSerialization() throws {
        let expression = StudioMIDIExpressionEditing.makeEvent(
            at: 1.5, lane: .expression, normalized: 0.75, channel: 3)!
        let bend = StudioMIDIExpressionEditing.makeEvent(
            at: 2.5, lane: .pitchBend, normalized: 0.8, channel: 3)!
        let data = try JSONEncoder().encode([expression, bend])
        let decoded = try JSONDecoder().decode([MIDIEvent].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].channel, 3)
        XCTAssertEqual(decoded[1].channel, 3)
        XCTAssertEqual(decoded[0].beatPosition, 1.5)
        XCTAssertEqual(decoded[1].beatPosition, 2.5)
        XCTAssertNotNil(StudioMIDIExpressionEditing.normalizedValue(
            of: decoded[0], for: .expression, channel: 3))
        XCTAssertNotNil(StudioMIDIExpressionEditing.normalizedValue(
            of: decoded[1], for: .pitchBend, channel: 3))
    }

    func testBinaryArticulationCC68Legato() {
        let event = StudioMIDIExpressionEditing.makeEvent(
            at: 3, lane: .legato, normalized: 0.9)
        if case .controlChange(let controller, let value) = event!.type {
            XCTAssertEqual(controller, 68)
            XCTAssertEqual(value, 127)
        } else { XCTFail("Expected CC68") }
    }

    func testInstantOrchestraExpressionModeIsDiscreteAndBlendsAreContinuous() {
        let gm = StudioMIDIExpressionEditing.makeEvent(
            at: 1, lane: .expressionMode, normalized: 0.1)!
        let gpo = StudioMIDIExpressionEditing.makeEvent(
            at: 2, lane: .expressionMode, normalized: 0.9)!
        let blend = StudioMIDIExpressionEditing.makeEvent(
            at: 3, lane: .blend1, normalized: 0.25)!
        if case .controlChange(let cc, let value) = gm.type {
            XCTAssertEqual(cc, 104)
            XCTAssertEqual(value, 0)
        } else { XCTFail("Expected CC104 GM mode") }
        if case .controlChange(let cc, let value) = gpo.type {
            XCTAssertEqual(cc, 104)
            XCTAssertEqual(value, 127)
        } else { XCTFail("Expected CC104 GPO mode") }
        if case .controlChange(let cc, let value) = blend.type {
            XCTAssertEqual(cc, 30)
            XCTAssertEqual(value, 32)
        } else { XCTFail("Expected CC30 continuous texture blend") }
    }

    func testGPOAutoLegatoControllerIsDiscrete() {
        let off = StudioMIDIExpressionEditing.makeEvent(
            at: 0, lane: .autoLegato, normalized: 0)!
        let on = StudioMIDIExpressionEditing.makeEvent(
            at: 1, lane: .autoLegato, normalized: 1)!
        if case .controlChange(let c0, let v0) = off.type,
           case .controlChange(let c1, let v1) = on.type {
            XCTAssertEqual(c0, 102)
            XCTAssertEqual(v0, 0)
            XCTAssertEqual(c1, 102)
            XCTAssertEqual(v1, 127)
        } else { XCTFail("Expected CC102 auto-legato switches") }
    }

    func testDrawingPreservesAnotherChannelAndControllers() {
        let a = MIDIEvent.controlChange(at: 1, controller: 1, value: 10, channel: 1)
        let b = MIDIEvent.controlChange(at: 1, controller: 11, value: 20, channel: 0)
        let c = MIDIEvent.pitchBend(at: 1, value: 800)
        let result = StudioMIDIExpressionEditing.draw(
            events: [a, b, c], lane: .modulation,
            points: [.init(beat: 1, value: 0.2)],
            clipStartBeat: 0, division: 0.25, channel: 0)
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.contains(where: { $0.id == a.id }))
        XCTAssertTrue(result.contains(where: { $0.id == b.id }))
        XCTAssertTrue(result.contains(where: { $0.id == c.id }))
    }
}
