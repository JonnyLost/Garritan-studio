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
