import XCTest
@testable import DAWCore

final class StudioMIDIClockMathTests: XCTestCase {
    func testMusicalBeatToSampleConversionAcrossPortableMacRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            XCTAssertEqual(
                StudioMIDIClockMath.samples(
                    forBeats: 4, tempoBPM: 120, sampleRate: rate
                ), Int64(rate * 2)
            )
            XCTAssertEqual(
                StudioMIDIClockMath.beats(
                    forSamples: Int64(rate * 2), tempoBPM: 120,
                    sampleRate: rate
                ), 4, accuracy: 1e-10
            )
        }
    }

    func testTempoChangesAndNegativePreroll() {
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: 3, tempoBPM: 90, sampleRate: 48_000
        ), 96_000)
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: -1, tempoBPM: 120, sampleRate: 48_000
        ), -24_000)
    }

    func testInvalidAndExtremeClockInputsCannotTrap() {
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: .nan, tempoBPM: 120, sampleRate: 44_100
        ), 0)
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: 4, tempoBPM: 0, sampleRate: 44_100
        ), 0)
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: 4, tempoBPM: 120, sampleRate: .infinity
        ), 0)
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: 1e300, tempoBPM: 0.01, sampleRate: 96_000
        ), Int64.max)
        XCTAssertEqual(StudioMIDIClockMath.samples(
            forBeats: -1e300, tempoBPM: 0.01, sampleRate: 96_000
        ), Int64.min)
        XCTAssertEqual(StudioMIDIClockMath.beats(
            forSamples: 100, tempoBPM: 0, sampleRate: 48_000
        ), 0)
    }

    func testRenderWindowEndIsExclusiveAndOverflowSafe() {
        XCTAssertEqual(StudioMIDIClockMath.bufferEnd(
            startSample: 1000, frameCount: 512
        ), 1512)
        XCTAssertEqual(StudioMIDIClockMath.bufferEnd(
            startSample: Int64.max - 2, frameCount: 512
        ), Int64.max)
        XCTAssertEqual(StudioMIDIClockMath.bufferEnd(
            startSample: -100, frameCount: 128
        ), 28)
    }
}
