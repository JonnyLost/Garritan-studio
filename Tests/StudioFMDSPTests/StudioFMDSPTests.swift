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


    func testNewPatchStartsAtTargetPitchInsteadOfGlidingFromOldPatch() {
        let synth = makeSynth()
        defer { sfm_destroy(synth) }
        for op in [SFM_OP2_BASE, SFM_OP3_BASE, SFM_OP4_BASE] {
            XCTAssertEqual(sfm_set_parameter(synth, op + SFM_OP_LEVEL, 0), 1)
        }
        XCTAssertEqual(sfm_set_parameter(synth, SFM_OP1_BASE + SFM_OP_RATIO, 2), 1)
        XCTAssertEqual(sfm_note_on(synth, 69, 127), 1)
        let first = render(synth, frames: 1_024)
        let crossings = zip(first, first.dropFirst())
            .filter { $0.0 <= 0 && $0.1 > 0 }.count
        XCTAssertEqual(crossings, 20, accuracy: 2,
                       "An offline patch load before a note must start at A5")
    }

    func testCC1ModulatesHarmonicBrightnessOnlyWhenEnabled() {
        let dry = makeSynth()
        let driven = makeSynth()
        defer { sfm_destroy(dry); sfm_destroy(driven) }
        for s in [dry, driven] {
            XCTAssertEqual(sfm_set_parameter(s, SFM_PARAM_MOD_TARGET, 1), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_PARAM_MOD_DEPTH, 1), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP2_BASE + SFM_OP_LEVEL, 0.75), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP3_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP4_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_note_on(s, 69, 110), 1)
        }
        XCTAssertEqual(sfm_midi_event(driven, 0xB0, 1, 127, 0), 1)
        let withoutWheel = render(dry, frames: 4_096)
        let withWheel = render(driven, frames: 4_096)
        let difference = zip(withoutWheel, withWheel)
            .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
        XCTAssertGreaterThan(difference, 5,
                             "CC1 should change the actual rendered FM spectrum")
    }

    func testCC1VibratoChangesPitchMotionWithoutTouchingOtherChannels() {
        let plain = makeSynth()
        let vibrato = makeSynth()
        defer { sfm_destroy(plain); sfm_destroy(vibrato) }
        for s in [plain, vibrato] {
            XCTAssertEqual(sfm_set_parameter(s, SFM_PARAM_MOD_TARGET, 0), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_PARAM_MOD_DEPTH, 1), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_PARAM_MOD_RATE, 6), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP2_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP3_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP4_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_midi_event(s, 0x90, 69, 110, 0), 1)
        }
        // An active wheel on the wrong MIDI channel must not change a voice.
        XCTAssertEqual(sfm_midi_event(vibrato, 0xB1, 1, 127, 0), 1)
        let unaltered = render(vibrato, frames: 2_048)
        let baseline = render(plain, frames: 2_048)
        XCTAssertEqual(unaltered, baseline)

        XCTAssertEqual(sfm_midi_event(vibrato, 0xB0, 1, 127, 0), 1)
        let modulated = render(vibrato, frames: 8_192)
        let unmodulated = render(plain, frames: 8_192)
        let difference = zip(modulated, unmodulated)
            .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
        XCTAssertGreaterThan(difference, 5)
    }

    func testVelocityBrightensModulatorsWithoutOnlyChangingOutputAmplitude() {
        let soft = makeSynth()
        let neutral = makeSynth()
        defer { sfm_destroy(soft); sfm_destroy(neutral) }
        for s in [soft, neutral] {
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP2_BASE + SFM_OP_LEVEL, 0.8), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP3_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_set_parameter(s, SFM_OP4_BASE + SFM_OP_LEVEL, 0), 1)
            XCTAssertEqual(sfm_note_on(s, 69, 40), 1)
        }
        XCTAssertEqual(sfm_set_parameter(soft, SFM_PARAM_VELOCITY_BRIGHTNESS, 1), 1)
        let softened = render(soft, frames: 4_096)
        let unchanged = render(neutral, frames: 4_096)
        let difference = zip(softened, unchanged)
            .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
        XCTAssertGreaterThan(difference, 3)
    }

    func testOutputGainSlewsRatherThanCuttingAtBlockBoundary() {
        let synth = makeSynth()
        defer { sfm_destroy(synth) }
        XCTAssertEqual(sfm_note_on(synth, 69, 127), 1)
        _ = render(synth, frames: 2_048)
        XCTAssertEqual(sfm_set_parameter(synth, SFM_PARAM_OUTPUT_GAIN, 0), 1)
        let fade = render(synth, frames: 6_615)
        XCTAssertGreaterThan(fade.prefix(256).map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertLessThan(fade.suffix(256).map { abs($0) }.max() ?? 1, 0.002)
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
