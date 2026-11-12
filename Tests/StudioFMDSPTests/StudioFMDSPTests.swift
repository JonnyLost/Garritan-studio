import XCTest
import StudioFMDSP

final class StudioFMDSPTests: XCTestCase {
    private func makeSynth() -> OpaquePointer {
        guard let synth = sfm_create(44_100, 8) else {
            fatalError("Native FM DSP initialization failed")
        }
        return synth
    }

    private func render(_ synth: OpaquePointer, frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                sfm_render(synth, l.baseAddress, r.baseAddress, Int32(frames))
            }
        }
        XCTAssertEqual(left, right)
        XCTAssertTrue(left.allSatisfy { $0.isFinite && abs($0) <= 1.001 })
        return left
    }

    func testCarrierOnlyConcertA440() {
        let synth = makeSynth()
        defer { sfm_destroy(synth) }
        for base in [SFM_OP2_BASE, SFM_OP3_BASE, SFM_OP4_BASE] {
            XCTAssertEqual(sfm_set_parameter(synth, base + SFM_OP_LEVEL, 0), 1)
        }
        XCTAssertEqual(sfm_note_on(synth, 69, 120), 1)
        let sample = render(synth, frames: 44_100)
        let zeroCrossings = zip(sample, sample.dropFirst())
            .filter { $0.0 <= 0 && $0.1 > 0 }.count
        XCTAssertEqual(zeroCrossings, 440, accuracy: 12)
        XCTAssertGreaterThan(sample.map { abs($0) }.max() ?? 0, 0.05)
    }

    func testDifferentFmAlgorithmsChangeWaveform() {
        let synth = makeSynth()
        defer { sfm_destroy(synth) }
        XCTAssertEqual(sfm_set_parameter(synth, SFM_PARAM_ALGORITHM, 1.25), 0)
        XCTAssertEqual(sfm_set_parameter(synth, SFM_PARAM_ALGORITHM, 4), 0)
        XCTAssertEqual(sfm_set_parameter(synth, SFM_OP1_BASE + SFM_OP_RATIO, 0), 0)
        XCTAssertEqual(sfm_set_parameter(synth, SFM_OP2_BASE + SFM_OP_LEVEL, 0.8), 1)
        XCTAssertEqual(sfm_note_on(synth, 69, 110), 1)
        let serial = render(synth, frames: 1_024)
        XCTAssertEqual(sfm_all_notes_off(synth), 1)
        _ = render(synth, frames: 128)
        XCTAssertEqual(sfm_set_parameter(synth, SFM_PARAM_ALGORITHM, 3), 1)
        XCTAssertEqual(sfm_note_on(synth, 69, 110), 1)
        let parallel = render(synth, frames: 1_024)
        let difference = zip(serial, parallel)
            .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
        XCTAssertGreaterThan(difference, 5)
    }

    func testFrameOffsetsCarryAcrossRenderBuffers() {
        let synth = makeSynth()
        defer { sfm_destroy(synth) }
        XCTAssertEqual(sfm_midi_event(synth, 0x90, 60, 100, 300), 1)
        XCTAssertTrue(render(synth, frames: 128).allSatisfy { $0 == 0 })
        let second = render(synth, frames: 256)
        XCTAssertTrue(second.prefix(172).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(second.suffix(84).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(sfm_all_notes_off(synth), 1)
        XCTAssertTrue(render(synth, frames: 128).allSatisfy { $0 == 0 })
        XCTAssertEqual(sfm_midi_event(synth, 0xB0, 20, 100, 0), 0)
    }

    func testSustainPedalAndRelease() {
        let synth = makeSynth()
        defer { sfm_destroy(synth) }
        XCTAssertEqual(sfm_note_on(synth, 60, 120), 1)
        _ = render(synth, frames: 1_024)
        XCTAssertEqual(sfm_midi_event(synth, 0xB0, 64, 127, 0), 1)
        XCTAssertEqual(sfm_note_off(synth, 60), 1)
        XCTAssertGreaterThan(render(synth, frames: 1_024).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(sfm_midi_event(synth, 0xB0, 64, 0, 0), 1)
        _ = render(synth, frames: 22_050)
        XCTAssertLessThan(render(synth, frames: 1_024).map { abs($0) }.max() ?? 1, 0.0001)
    }
}
