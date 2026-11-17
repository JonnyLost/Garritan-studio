import Foundation
import XCTest
@testable import DAWCore

final class StudioAppleGeneralMIDITests: XCTestCase {
    func testCompleteFactoryMelodicCatalogAndZeroBasedNumbers() {
        XCTAssertEqual(StudioAppleGeneralMIDI.names.count, 128)
        XCTAssertEqual(StudioAppleGeneralMIDI.name(for: 0), "Acoustic Grand Piano")
        XCTAssertEqual(StudioAppleGeneralMIDI.name(for: 24), "Acoustic Guitar (Nylon)")
        XCTAssertEqual(StudioAppleGeneralMIDI.name(for: 80), "Lead 1 (Square)")
        XCTAssertEqual(StudioAppleGeneralMIDI.name(for: 127), "Gunshot")
        XCTAssertEqual(StudioAppleGeneralMIDI.family(for: 0), "Piano")
        XCTAssertEqual(StudioAppleGeneralMIDI.category(for: 80), "Synth")
        XCTAssertEqual(StudioAppleGeneralMIDI.family(for: 127), "Sound Effects")
    }

    func testAppleProgramSavedAndOldProjectStillDefaultsToPiano() throws {
        var track = Track(name: "Apple Pad", type: .instrument)
        XCTAssertNil(track.appleGeneralMIDIProgram)
        track.appleGeneralMIDIProgram = 88
        let encoded = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: encoded)
        XCTAssertEqual(decoded.appleGeneralMIDIProgram, 88)

        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dictionary.removeValue(forKey: "appleGeneralMIDIProgram")
        let legacyData = try JSONSerialization.data(withJSONObject: dictionary)
        let legacy = try JSONDecoder().decode(Track.self, from: legacyData)
        XCTAssertNil(legacy.appleGeneralMIDIProgram)
        XCTAssertEqual(StudioAppleGeneralMIDI.name(for: legacy.appleGeneralMIDIProgram ?? 0),
                       "Acoustic Grand Piano")
    }
}
