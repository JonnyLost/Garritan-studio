import XCTest
import DAWCore
@testable import DAWUI

final class StudioMusicalGridTests: XCTestCase {
    func testBarLengthUsesDenominatorInQuarterNoteBeats() {
        XCTAssertEqual(StudioMusicalGrid.beatsPerBar(.common), 4)
        XCTAssertEqual(StudioMusicalGrid.beatsPerBar(.waltz), 3)
        XCTAssertEqual(StudioMusicalGrid.beatsPerBar(.sixEight), 3)
        XCTAssertEqual(StudioMusicalGrid.beatsPerBar(TimeSignature(numerator: 7, denominator: 8)), 3.5)
        XCTAssertEqual(StudioMusicalGrid.beatsPerBar(TimeSignature(numerator: 2, denominator: 2)), 4)
    }

    func testBarSnapRespectsTimeSignature() {
        XCTAssertEqual(StudioMusicalGrid.snap(2.7, mode: .bar, timeSignature: .sixEight), 3)
        XCTAssertEqual(StudioMusicalGrid.snap(3.35, mode: .bar,
                                              timeSignature: TimeSignature(numerator: 7, denominator: 8)), 3.5)
        XCTAssertEqual(StudioMusicalGrid.snap(2.7, mode: .bar, timeSignature: .waltz), 3)
    }

    func testSubdivisionAndModifierBypass() {
        XCTAssertEqual(StudioMusicalGrid.snap(2.26, mode: .sixteenth, timeSignature: .common), 2.25)
        XCTAssertEqual(StudioMusicalGrid.snap(2.26, mode: .off, timeSignature: .common), 2.26)
        XCTAssertEqual(StudioMusicalGrid.snap(2.26, mode: .beat,
                                              timeSignature: .common, bypass: true), 2.26)
    }

    func testGridClampsNegativeBeatsAndInvalidInputs() {
        XCTAssertEqual(StudioMusicalGrid.snap(-3, division: 0.25), 0)
        XCTAssertEqual(StudioMusicalGrid.snap(.infinity, division: 1), 0)
        XCTAssertEqual(StudioMusicalGrid.snap(4.25, division: 0), 4.25)
    }
}
