import XCTest
import StudioAnalogDSP

final class StudioAnalogDSPTests: XCTestCase {
    private func makeSynth(voices: Int32 = 8) -> OpaquePointer {
        guard let synth = sa_create(44_100, voices) else {
            fatalError("Unable to construct Studio Analog")
        }
        return synth
    }

    private func render(_ synth: OpaquePointer, frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                sa_render(synth, l.baseAddress, r.baseAddress, Int32(frames))
            }
        }
        XCTAssertEqual(left, right, "Stereo channels must start identical")
        XCTAssertTrue(left.allSatisfy { $0.isFinite && abs($0) <= 1 })
        return left
    }

    func testSineOscillatorIsAudibleAndTunedToA440() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        XCTAssertEqual(sa_set_parameter(synth, 0, 0), 1) // sine
        XCTAssertEqual(sa_set_parameter(synth, 3, 0), 1) // disable osc2
        XCTAssertEqual(sa_set_parameter(synth, 6, 18_000), 1) // open filter
        XCTAssertEqual(sa_note_on(synth, 69, 120), 1)

        let samples = render(synth, frames: 11_025)
        let steady = samples.dropFirst(1_024)
        let risingZeroCrossings = zip(steady, steady.dropFirst())
            .filter { $0.0 <= 0 && $0.1 > 0 }.count
        let measuredHz = Double(risingZeroCrossings) * 44_100 / Double(steady.count)
        XCTAssertEqual(measuredHz, 440, accuracy: 12)
        XCTAssertGreaterThan(steady.map { abs($0) }.max() ?? 0, 0.01)
    }

    func testNoteOffEventuallySilencesSynth() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        XCTAssertEqual(sa_note_on(synth, 60, 100), 1)
        _ = render(synth, frames: 8_192)
        XCTAssertEqual(sa_note_off(synth, 60), 1)
        let tail = render(synth, frames: 22_050)
        XCTAssertLessThan(tail.suffix(2_048).map { abs($0) }.max() ?? 1, 0.00001)
    }

    func testPolyphonyAndParameterValidation() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        XCTAssertEqual(sa_note_on(synth, 60, 110), 1)
        XCTAssertEqual(sa_note_on(synth, 64, 110), 1)
        XCTAssertEqual(sa_note_on(synth, 67, 110), 1)
        let samples = render(synth, frames: 2_048)
        XCTAssertGreaterThan(samples.reduce(0.0) { $0 + Double(abs($1)) }, 1.0)
        XCTAssertEqual(sa_set_parameter(synth, 6, -1), 0)
        XCTAssertEqual(sa_set_parameter(synth, 0, 2.5), 0)
        XCTAssertEqual(sa_set_parameter(synth, 19, .nan), 0)
        XCTAssertEqual(sa_get_parameter(synth, 19), 0.45, accuracy: 0.0001)
    }

    func testRejectsBadGraphWithoutDestroyingCurrentPatch() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        let cycle = [
            SARoute(source: 3, destination: 6, destinationInput: 0, gain: 1),
            SARoute(source: 6, destination: 3, destinationInput: 0, gain: 1),
            SARoute(source: 6, destination: 8, destinationInput: 0, gain: 1),
            SARoute(source: 7, destination: 8, destinationInput: 1, gain: 1),
            SARoute(source: 8, destination: 9, destinationInput: 0, gain: 1)
        ]
        let accepted = cycle.withUnsafeBufferPointer {
            sa_load_patch(synth, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(accepted, 0)
        XCTAssertEqual(sa_note_on(synth, 60, 100), 1)
        XCTAssertGreaterThan(render(synth, frames: 3_000).map { abs($0) }.max() ?? 0, 0.001)
    }

    func testRenderBoundaryLiveGraphSwapsAndBusyBackPressure() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        let direct = [
            SARoute(source: 0, destination: 6, destinationInput: 0, gain: 1),
            SARoute(source: 6, destination: 8, destinationInput: 0, gain: 1),
            SARoute(source: 7, destination: 8, destinationInput: 1, gain: 1),
            SARoute(source: 8, destination: 9, destinationInput: 0, gain: 1)
        ]
        func submit(_ routes: [SARoute]) -> Int32 {
            routes.withUnsafeBufferPointer {
                sa_submit_patch(synth, $0.baseAddress, $0.count)
            }
        }
        XCTAssertEqual(submit(direct), 1)
        XCTAssertEqual(submit(direct), -1, "Pending render-boundary swap must not be overwritten")
        XCTAssertEqual(sa_note_on(synth, 69, 100), 1)
        let samples = render(synth, frames: 2_048)
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(submit(direct), 1)
        _ = render(synth, frames: 256)
        for _ in 0..<100 {
            XCTAssertEqual(submit(direct), 1)
            let block = render(synth, frames: 128)
            XCTAssertTrue(block.allSatisfy(\.isFinite))
        }
    }

    func testNoteTimingAcrossBlocksAndSustain() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        XCTAssertEqual(sa_midi_event(synth, 0x90, 69, 127, 300), 1)
        XCTAssertTrue(render(synth, frames: 128).allSatisfy { $0 == 0 })
        let second = render(synth, frames: 256)
        XCTAssertTrue(second.prefix(172).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(second.suffix(84).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(sa_midi_event(synth, 0xB0, 64, 127, 0), 1)
        XCTAssertEqual(sa_midi_event(synth, 0x80, 69, 0, 0), 1)
        _ = render(synth, frames: 8192)
        XCTAssertGreaterThan(render(synth, frames: 512).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(sa_midi_event(synth, 0xB0, 64, 0, 0), 1)
        _ = render(synth, frames: 22050)
        XCTAssertLessThan(render(synth, frames: 2048).map { abs($0) }.max() ?? 1, 0.0001)
    }

    func testPitchWheelRaisesA440ByTwoSemitones() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        XCTAssertEqual(sa_set_parameter(synth, 0, 0), 1)
        XCTAssertEqual(sa_set_parameter(synth, 3, 0), 1)
        XCTAssertEqual(sa_set_parameter(synth, 6, 18000), 1)
        XCTAssertEqual(sa_midi_event(synth, 0x90, 69, 127, 0), 1)
        _ = render(synth, frames: 1000)
        func crossings(_ samples: [Float]) -> Int {
            zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        }
        XCTAssertEqual(crossings(render(synth, frames: 44100)), 440, accuracy: 12)
        XCTAssertEqual(sa_midi_event(synth, 0xE0, 127, 127, 0), 1)
        XCTAssertEqual(crossings(render(synth, frames: 44100)), 494, accuracy: 12)
        XCTAssertEqual(sa_midi_event(synth, 0xB0, 1, 127, 0), 1)
        XCTAssertEqual(sa_midi_event(synth, 0xB0, 120, 0, 0), 1)
        XCTAssertTrue(render(synth, frames: 128).allSatisfy { $0 == 0 })
    }

    func testOverlapNoteOffReleasesOneVoiceOnly() {
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        XCTAssertEqual(sa_midi_event(synth, 0x90, 60, 110, 0), 1)
        XCTAssertEqual(sa_midi_event(synth, 0x90, 60, 110, 0), 1)
        _ = render(synth, frames: 512)
        XCTAssertEqual(sa_midi_event(synth, 0x80, 60, 0, 0), 1)
        _ = render(synth, frames: 8192)
        XCTAssertGreaterThan(render(synth, frames: 1024).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(sa_midi_event(synth, 0x80, 60, 0, 0), 1)
        _ = render(synth, frames: 22050)
        XCTAssertLessThan(render(synth, frames: 1024).map { abs($0) }.max() ?? 1, 0.0001)
    }

    func testRejectsInvalidConstructionAndMidiQueueIsBounded() {
        XCTAssertNil(sa_create(0, 8))
        XCTAssertNil(sa_create(44_100, 100))
        let synth = makeSynth()
        defer { sa_destroy(synth) }
        var accepted = 0
        for _ in 0..<300 {
            accepted += Int(sa_note_on(synth, 60, 80))
        }
        XCTAssertEqual(accepted, 256)
        _ = render(synth, frames: 32)
        XCTAssertEqual(sa_all_notes_off(synth), 1)
        _ = render(synth, frames: 4_096)
    }
}
