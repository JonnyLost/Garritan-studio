import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioAnalogTrackIntegrationTests: XCTestCase {
    func testNewNativeSynthCreatesStereoSourceAndAcceptsMIDI() throws {
        let synth = try StudioAnalogInstrument(sampleRate: 44_100)
        XCTAssertTrue(synth.audioNode is AVAudioSourceNode)
        XCTAssertEqual(synth.format.sampleRate, 44_100)
        XCTAssertEqual(synth.format.channelCount, 2)
        XCTAssertFalse(synth.format.isInterleaved)

        XCTAssertTrue(synth.noteOn(60, velocity: 100))
        XCTAssertTrue(synth.noteOff(60))
        XCTAssertTrue(synth.allNotesOff())
        XCTAssertTrue(synth.setParameter(6, value: 2_500))
        XCTAssertEqual(synth.parameter(6), 2_500, accuracy: 0.01)
        XCTAssertFalse(synth.setParameter(6, value: -1))
    }

    func testNativeInstrumentStatePersistsAndOldProjectStillDecodes() throws {
        var track = Track(name: "Studio Analog", type: .instrument)
        track.studioAnalogEnabled = true
        let encoded = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: encoded)
        XCTAssertEqual(decoded.studioAnalogEnabled, true)
        XCTAssertNil(decoded.instrumentSlot)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "studioAnalogEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let oldProjectTrack = try JSONDecoder().decode(Track.self, from: legacyData)
        XCTAssertNil(oldProjectTrack.studioAnalogEnabled)
    }
}
