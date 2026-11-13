import XCTest
import StudioWavetableDSP

final class StudioWavetableDSPTests: XCTestCase {
    private func render(_ synth: OpaquePointer, frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                sws_render(synth, l.baseAddress, r.baseAddress, Int32(frames))
            }
        }
        XCTAssertEqual(left, right)
        XCTAssertTrue(left.allSatisfy { $0.isFinite && abs($0) <= 1.00001 })
        return left
    }

    func testBandlimitedTableMorphAndCustomPartials() throws {
        let a = try XCTUnwrap(sws_create(44_100, 8))
        let b = try XCTUnwrap(sws_create(44_100, 8))
        defer { sws_destroy(a); sws_destroy(b) }
        XCTAssertEqual(sws_get_parameter(a, SWS_PARAM_OSC1_POSITION), 2)
        XCTAssertEqual(sws_set_parameter(a, SWS_PARAM_OSC2_LEVEL, 0), 1)
        XCTAssertEqual(sws_set_parameter(b, SWS_PARAM_OSC2_LEVEL, 0), 1)
        XCTAssertEqual(sws_set_parameter(a, SWS_PARAM_OSC1_POSITION, 0), 1)
        XCTAssertEqual(sws_set_parameter(b, SWS_PARAM_OSC1_POSITION, 4), 1)
        XCTAssertEqual(sws_note_on(a, 69, 110), 1)
        XCTAssertEqual(sws_note_on(b, 69, 110), 1)
        let plain = render(a, frames: 4_096)
        let glass = render(b, frames: 4_096)
        let difference = zip(plain, glass)
            .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
        XCTAssertGreaterThan(difference, 5)

        sws_reset_stopped(a)
        sws_reset_stopped(b)
        XCTAssertEqual(sws_set_parameter(a, SWS_PARAM_OSC1_POSITION, 5), 1)
        XCTAssertEqual(sws_set_parameter(b, SWS_PARAM_OSC1_POSITION, 5), 1)
        XCTAssertEqual(sws_set_parameter(b, SWS_PARAM_PARTIAL_BASE + 4, 0.9), 1)
        XCTAssertEqual(sws_note_on(a, 69, 100), 1)
        XCTAssertEqual(sws_note_on(b, 69, 100), 1)
        let pure = render(a, frames: 4_096)
        let altered = render(b, frames: 4_096)
        XCTAssertGreaterThan(zip(pure, altered)
            .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }, 5)
    }

    func testMidiValidationAndSustain() throws {
        let synth = try XCTUnwrap(sws_create(44_100, 8))
        defer { sws_destroy(synth) }
        XCTAssertEqual(sws_set_parameter(synth, SWS_PARAM_OSC2_DETUNE, .nan), 0)
        XCTAssertEqual(sws_set_parameter(synth, SWS_PARAM_OUTPUT_GAIN, -1), 0)
        XCTAssertEqual(sws_midi_event(synth, 0xf0, 0, 0, 0), 0)
        XCTAssertEqual(sws_midi_event(synth, 0x90, 69, 110, 65_536), 0)
        XCTAssertEqual(sws_midi_event(synth, 0xb0, 1, 100, 0), 1)
        XCTAssertEqual(sws_midi_event(synth, 0xb0, 64, 127, 0), 1)
        XCTAssertEqual(sws_note_on(synth, 69, 110), 1)
        _ = render(synth, frames: 512)
        XCTAssertEqual(sws_note_off(synth, 69), 1)
        XCTAssertGreaterThan(render(synth, frames: 2_048).map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertEqual(sws_midi_event(synth, 0xb0, 64, 0, 0), 1)
        _ = render(synth, frames: 22_050)
        XCTAssertLessThan(render(synth, frames: 512).map { abs($0) }.max() ?? 1, 0.0001)
        XCTAssertEqual(sws_all_notes_off(synth), 1)
        XCTAssertTrue(render(synth, frames: 512).allSatisfy { $0 == 0 })
    }
}
