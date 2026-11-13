import XCTest
import StudioPhysicalDSP

final class StudioPhysicalDSPTests: XCTestCase {
    private func makeSynth(_ rate: Double = 44_100) -> OpaquePointer {
        guard let synth = spm_create(rate, 8) else {
            fatalError("Physical-modeling DSP creation failed")
        }
        return synth
    }

    private func render(_ synth: OpaquePointer, count: Int) -> [Float] {
        var left = [Float](repeating: 0, count: count)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                spm_render(synth, l.baseAddress, r.baseAddress, Int32(count))
            }
        }
        XCTAssertEqual(left, right)
        XCTAssertTrue(left.allSatisfy { $0.isFinite && abs($0) <= 1.001 })
        return left
    }

    func testA440PluckedStringHasStableFundamentalAndFiniteSamples() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        XCTAssertEqual(spm_note_on(synth, 69, 127), 1)
        let samples = render(synth, count: 44_100)
        let crossings = zip(samples, samples.dropFirst())
            .filter { $0.0 <= 0 && $0.1 > 0 }.count
        XCTAssertEqual(crossings, 440, accuracy: 16)
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.01)
    }

    func testParametersRejectInvalidOrNonfiniteValues() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 1), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 0.5), 0)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_GAIN, 2), 0)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_GAIN, .nan), 0)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_POSITION, 0), 0)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_RELEASE, 0.2), 1)
        XCTAssertEqual(spm_get_parameter(synth, SPM_PARAM_RELEASE), 0.2, accuracy: 0.0001)
        XCTAssertNil(spm_create(44_100, 9))
        XCTAssertNil(spm_create(0, 8))
    }

    func testSampleAccurateEventsCarryAcrossBuffersAndPanicClearsOutput() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        XCTAssertEqual(spm_midi_event(synth, 0x90, 69, 120, 300), 1)
        XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })
        let second = render(synth, count: 256)
        XCTAssertTrue(second.prefix(172).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(second.suffix(84).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(spm_all_notes_off(synth), 1)
        XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })
        XCTAssertEqual(spm_midi_event(synth, 0xB0, 74, 100, 0), 0)
    }

    func testStruckAndPluckedExcitationProduceDifferentWaveforms() {
        let pluck = makeSynth()
        let strike = makeSynth()
        defer { spm_destroy(pluck); spm_destroy(strike) }
        XCTAssertEqual(spm_set_parameter(strike, SPM_PARAM_MODEL, 1), 1)
        XCTAssertEqual(spm_note_on(pluck, 60, 120), 1)
        XCTAssertEqual(spm_note_on(strike, 60, 120), 1)
        let a = render(pluck, count: 4_096)
        let b = render(strike, count: 4_096)
        let difference = zip(a, b).reduce(0.0) {
            $0 + Double(abs($1.0 - $1.1))
        }
        XCTAssertGreaterThan(difference, 1)
    }


    func testNewExpressiveParametersAreValidatedAndDefaulted() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        for id in [SPM_PARAM_PICK_HARDNESS, SPM_PARAM_STIFFNESS,
                   SPM_PARAM_BODY_SIZE] {
            XCTAssertEqual(spm_set_parameter(synth, id, 0), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, 1), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, -0.1), 0)
            XCTAssertEqual(spm_set_parameter(synth, id, 1.1), 0)
            XCTAssertEqual(spm_set_parameter(synth, id, .infinity), 0)
        }
    }

    func testPickHardnessChangesPluckedTransient() {
        let soft = makeSynth()
        let hard = makeSynth()
        defer { spm_destroy(soft); spm_destroy(hard) }
        XCTAssertEqual(spm_set_parameter(soft, SPM_PARAM_PICK_HARDNESS, 0), 1)
        XCTAssertEqual(spm_set_parameter(hard, SPM_PARAM_PICK_HARDNESS, 1), 1)
        XCTAssertEqual(spm_note_on(soft, 69, 110), 1)
        XCTAssertEqual(spm_note_on(hard, 69, 110), 1)
        let a = render(soft, count: 2_048)
        let b = render(hard, count: 2_048)
        XCTAssertGreaterThan(zip(a,b).reduce(0.0) {
            $0 + Double(abs($1.0 - $1.1))
        }, 1)
    }

    func testBodySizeAndStiffnessAlterTimbreWithoutNonfiniteOutput() {
        let baseline = makeSynth()
        let changed = makeSynth()
        defer { spm_destroy(baseline); spm_destroy(changed) }
        XCTAssertEqual(spm_set_parameter(changed, SPM_PARAM_STIFFNESS, 1), 1)
        XCTAssertEqual(spm_set_parameter(changed, SPM_PARAM_BODY_SIZE, 1), 1)
        XCTAssertEqual(spm_set_parameter(changed, SPM_PARAM_BODY_MIX, 1), 1)
        XCTAssertEqual(spm_set_parameter(baseline, SPM_PARAM_BODY_MIX, 1), 1)
        XCTAssertEqual(spm_note_on(baseline, 57, 115), 1)
        XCTAssertEqual(spm_note_on(changed, 57, 115), 1)
        let a = render(baseline, count: 4_096)
        let b = render(changed, count: 4_096)
        XCTAssertGreaterThan(zip(a,b).reduce(0.0) {
            $0 + Double(abs($1.0 - $1.1))
        }, 0.1)
    }

    func testVoiceStealingAndPitchBendRemainFinite() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        for note in UInt8(48)...UInt8(72) {
            XCTAssertEqual(spm_note_on(synth, note, 100), 1)
        }
        _ = render(synth, count: 2_048)
        XCTAssertEqual(spm_midi_event(synth, 0xE0, 127, 127, 0), 1)
        let output = render(synth, count: 4_096)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1.001 })
        XCTAssertEqual(spm_all_notes_off(synth), 1)
        XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })
    }

    func testBowedModelAcceptsExpressionAndProducesSustainedSound() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 2), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_BOW_PRESSURE, 0.9), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_BOW_SPEED, 0.9), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_BOW_NOISE, 0.2), 1)
        XCTAssertEqual(spm_note_on(synth, 69, 127), 1)
        _ = render(synth, count: 22_050)
        let sustained = render(synth, count: 4_096)
        XCTAssertGreaterThan(sustained.map { abs($0) }.max() ?? 0, 0.00001)
        XCTAssertEqual(spm_midi_event(synth, 0xB0, 1, 0, 0), 1)
        XCTAssertEqual(spm_midi_event(synth, 0xB0, 11, 0, 0), 1)
        XCTAssertTrue(render(synth, count: 512).allSatisfy { $0 == 0 })
        XCTAssertEqual(spm_note_off(synth, 69), 1)
        _ = render(synth, count: 44_100)
        XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })
    }

    func testBowedPressureAndTextureAffectWaveform() {
        let a = makeSynth()
        let b = makeSynth()
        defer { spm_destroy(a); spm_destroy(b) }
        for synth in [a, b] {
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 2), 1)
            XCTAssertEqual(spm_note_on(synth, 60, 120), 1)
        }
        XCTAssertEqual(spm_set_parameter(a, SPM_PARAM_BOW_PRESSURE, 0.1), 1)
        XCTAssertEqual(spm_set_parameter(b, SPM_PARAM_BOW_PRESSURE, 1), 1)
        XCTAssertEqual(spm_set_parameter(b, SPM_PARAM_BOW_NOISE, 1), 1)
        let first = render(a, count: 4_096)
        let second = render(b, count: 4_096)
        XCTAssertGreaterThan(zip(first, second).reduce(0.0) {
            $0 + Double(abs($1.0 - $1.1))
        }, 0.001)
    }

    func testBowParametersRejectInvalidValues() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        for id in [SPM_PARAM_BOW_PRESSURE, SPM_PARAM_BOW_SPEED,
                   SPM_PARAM_BOW_NOISE] {
            XCTAssertEqual(spm_set_parameter(synth, id, 0), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, 1), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, -0.01), 0)
            XCTAssertEqual(spm_set_parameter(synth, id, .nan), 0)
        }
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 8), 0)
    }

    func testWindAndBrassModelsRenderAndRespondToBreath() {
        for model: Float in [3, 4] {
            let synth = makeSynth()
            defer { spm_destroy(synth) }
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, model), 1)
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_BREATH, 1), 1)
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_AIR_NOISE, 0.3), 1)
            XCTAssertEqual(spm_note_on(synth, 69, 120), 1)
            let sounding = render(synth, count: 8_192)
            XCTAssertGreaterThan(sounding.map { abs($0) }.max() ?? 0, 0.000001)
            XCTAssertEqual(spm_midi_event(synth, 0xB0, 2, 0, 0), 1)
            XCTAssertEqual(spm_midi_event(synth, 0xB0, 11, 0, 0), 1)
            XCTAssertTrue(render(synth, count: 512).allSatisfy { $0 == 0 })
            XCTAssertEqual(spm_all_notes_off(synth), 1)
            XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })
        }
    }

    func testWindControlsValidateRangesAndModelValues() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        for id in [SPM_PARAM_BREATH, SPM_PARAM_REED_STIFFNESS,
                   SPM_PARAM_AIR_NOISE, SPM_PARAM_BORE] {
            XCTAssertEqual(spm_set_parameter(synth, id, 0), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, 1), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, -0.01), 0)
            XCTAssertEqual(spm_set_parameter(synth, id, .nan), 0)
        }
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 4), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 8), 0)
    }

    func testMalletBellAndMembraneAreAudibleAndDistinct() {
        var outputs = [[Float]]()
        for model: Float in [5, 6, 7] {
            let synth = makeSynth()
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, model), 1)
            XCTAssertEqual(spm_note_on(synth, 69, 120), 1)
            let samples = render(synth, count: 4_096)
            XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.005)
            outputs.append(samples)
            spm_destroy(synth)
        }
        for (a, b) in [(0, 1), (1, 2), (0, 2)] {
            let difference = zip(outputs[a], outputs[b]).reduce(0.0) {
                $0 + Double(abs($1.0 - $1.1))
            }
            XCTAssertGreaterThan(difference, 0.1)
        }
    }

    func testPercussionMaterialAndHardnessChangeTheSpectrum() {
        let soft = makeSynth()
        let hard = makeSynth()
        defer { spm_destroy(soft); spm_destroy(hard) }
        for synth in [soft, hard] {
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 6), 1)
        }
        XCTAssertEqual(spm_set_parameter(soft, SPM_PARAM_PERC_HARDNESS, 0), 1)
        XCTAssertEqual(spm_set_parameter(soft, SPM_PARAM_PERC_INHARMONICITY, 0), 1)
        XCTAssertEqual(spm_set_parameter(hard, SPM_PARAM_PERC_HARDNESS, 1), 1)
        XCTAssertEqual(spm_set_parameter(hard, SPM_PARAM_PERC_INHARMONICITY, 1), 1)
        XCTAssertEqual(spm_note_on(soft, 60, 120), 1)
        XCTAssertEqual(spm_note_on(hard, 60, 120), 1)
        let a = render(soft, count: 4_096)
        let b = render(hard, count: 4_096)
        XCTAssertGreaterThan(zip(a,b).reduce(0.0) {
            $0 + Double(abs($1.0 - $1.1))
        }, 0.1)
    }

    func testMembraneNaturallyDecaysAndNoteOffDampsResonances() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 7), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_PERC_DECAY, 0), 1)
        XCTAssertEqual(spm_note_on(synth, 60, 120), 1)
        XCTAssertGreaterThan(render(synth, count: 2_048).map { abs($0) }.max() ?? 0, 0.001)
        _ = render(synth, count: 44_100)
        XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })

        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_PERC_DECAY, 1), 1)
        XCTAssertEqual(spm_note_on(synth, 60, 120), 1)
        _ = render(synth, count: 2_048)
        XCTAssertEqual(spm_note_off(synth, 60), 1)
        _ = render(synth, count: 44_100)
        XCTAssertTrue(render(synth, count: 128).allSatisfy { $0 == 0 })
    }

    func testPercussionPitchBendRetunesActiveModesAndPanicWorks() {
        let bent = makeSynth()
        let stable = makeSynth()
        defer { spm_destroy(bent); spm_destroy(stable) }
        for synth in [bent, stable] {
            XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 5), 1)
            XCTAssertEqual(spm_note_on(synth, 69, 127), 1)
            _ = render(synth, count: 2_048)
        }
        XCTAssertEqual(spm_midi_event(bent, 0xE0, 127, 127, 0), 1)
        let a = render(bent, count: 4_096)
        let b = render(stable, count: 4_096)
        XCTAssertGreaterThan(zip(a,b).reduce(0.0) {
            $0 + Double(abs($1.0 - $1.1))
        }, 0.1)
        XCTAssertEqual(spm_all_notes_off(bent), 1)
        XCTAssertTrue(render(bent, count: 128).allSatisfy { $0 == 0 })
    }

    func testPercussionParameterRangesAndHighRateStability() {
        let synth = makeSynth(384_000)
        defer { spm_destroy(synth) }
        for id in [SPM_PARAM_PERC_HARDNESS, SPM_PARAM_PERC_DECAY,
                   SPM_PARAM_PERC_INHARMONICITY, SPM_PARAM_PERC_ATTACK_NOISE] {
            XCTAssertEqual(spm_set_parameter(synth, id, 0), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, 1), 1)
            XCTAssertEqual(spm_set_parameter(synth, id, -0.1), 0)
            XCTAssertEqual(spm_set_parameter(synth, id, 1.1), 0)
            XCTAssertEqual(spm_set_parameter(synth, id, .nan), 0)
        }
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 7), 1)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 7.5), 0)
        XCTAssertEqual(spm_set_parameter(synth, SPM_PARAM_MODEL, 8), 0)
        XCTAssertEqual(spm_note_on(synth, 21, 127), 1)
        _ = render(synth, count: 16_384)
        XCTAssertEqual(spm_midi_event(synth, 0xE0, 0, 0, 0), 1)
        XCTAssertTrue(render(synth, count: 16_384).allSatisfy { $0.isFinite })
    }

    func testNoteReleaseSustainAndMultipleSampleRates() {
        let synth = makeSynth()
        defer { spm_destroy(synth) }
        XCTAssertEqual(spm_note_on(synth, 60, 127), 1)
        _ = render(synth, count: 2_048)
        XCTAssertEqual(spm_midi_event(synth, 0xB0, 64, 127, 0), 1)
        XCTAssertEqual(spm_note_off(synth, 60), 1)
        XCTAssertGreaterThan(render(synth, count: 256).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(spm_midi_event(synth, 0xB0, 64, 0, 0), 1)
        _ = render(synth, count: 44_100)
        XCTAssertTrue(render(synth, count: 256).allSatisfy { $0 == 0 })

        let highRate = makeSynth(384_000)
        defer { spm_destroy(highRate) }
        XCTAssertEqual(spm_note_on(highRate, 21, 110), 1)
        XCTAssertTrue(render(highRate, count: 16_384).allSatisfy { $0.isFinite })
    }
}
