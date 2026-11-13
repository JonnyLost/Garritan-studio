import XCTest
import Foundation
@testable import DAWCore

final class StudioSamplerOrchestralPatchTests: XCTestCase {
    private func zone(_ note: UInt8) -> StudioSamplerZone {
        StudioSamplerZone(sampleURL: URL(fileURLWithPath: "/tmp/Violin\(note).wav"),
                          rootNote: note, lowestNote: note, highestNote: note)
    }

    func testLegacyPatchStillDecodesWithDisabledOrchestralModes() throws {
        let legacy = StudioSamplerPatch(zones: [zone(60)])
        XCTAssertTrue(legacy.isValid)
        let restored = try JSONDecoder().decode(StudioSamplerPatch.self,
                                                from: JSONEncoder().encode(legacy))
        XCTAssertTrue(restored.isValid)
        XCTAssertNil(restored.legatoEnabled)
        XCTAssertNil(restored.legatoCrossfadeMilliseconds)
        XCTAssertNil(restored.microphones)
        XCTAssertNil(restored.zones[0].legatoFromNote)
        XCTAssertNil(restored.zones[0].microphoneID)
    }

    func testRoundTripPreservesMicrophonesRecordedTransitionsAndExpression() throws {
        var sustain = zone(62)
        sustain.microphoneID = 2
        var recorded = sustain
        recorded.legatoFromNote = 60
        var patch = StudioSamplerPatch(zones: [zone(60), sustain, recorded])
        patch.legatoEnabled = true
        patch.legatoCrossfadeMilliseconds = 52
        patch.vibratoCC21 = 48
        patch.breathCC2 = 92
        patch.microphones = [
            StudioSamplerMicrophone(id: 0, name: "Close", gain: 0.8, pan: -0.2),
            StudioSamplerMicrophone(id: 2, name: "Room", gain: 0.4, pan: 0.6)
        ]
        XCTAssertTrue(patch.isValid)
        let encoded = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(StudioSamplerPatch.self, from: encoded)
        XCTAssertEqual(decoded, patch)
        XCTAssertEqual(decoded.zones[2].legatoFromNote, 60)
        XCTAssertEqual(decoded.microphones?[1].gain, 0.4)
        XCTAssertEqual(decoded.vibratoCC21, 48)
        XCTAssertEqual(decoded.breathCC2, 92)
    }

    func testRejectsUnsafeOrContradictoryOrchestralMappings() {
        var transition = zone(62)
        transition.legatoFromNote = 62  // from cannot be destination
        XCTAssertFalse(transition.isValid)
        transition.legatoFromNote = 60
        transition.loopStartFrame = 10
        transition.loopEndFrame = 100
        XCTAssertFalse(transition.isValid)
        transition.loopStartFrame = nil
        transition.loopEndFrame = nil
        transition.isReleaseTrigger = true
        XCTAssertFalse(transition.isValid)
        transition.isReleaseTrigger = nil
        XCTAssertTrue(transition.isValid)

        var patch = StudioSamplerPatch(zones: [transition])
        patch.legatoCrossfadeMilliseconds = 999
        XCTAssertFalse(patch.isValid)
        patch.legatoCrossfadeMilliseconds = 40
        patch.microphones = [
            StudioSamplerMicrophone(id: 0, name: "Close"),
            StudioSamplerMicrophone(id: 0, name: "Duplicate")
        ]
        XCTAssertFalse(patch.isValid)
        patch.microphones = [StudioSamplerMicrophone(id: 0, name: "Close")]
        patch.zones[0].microphoneID = 3  // mic group 3 was not configured
        XCTAssertFalse(patch.isValid)
        patch.zones[0].microphoneID = 0
        XCTAssertTrue(patch.isValid)
    }
}
