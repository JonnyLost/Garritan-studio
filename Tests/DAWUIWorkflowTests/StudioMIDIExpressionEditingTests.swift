import XCTest
import DAWCore
@testable import DAWUI

final class StudioMIDIExpressionEditingTests: XCTestCase {
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
