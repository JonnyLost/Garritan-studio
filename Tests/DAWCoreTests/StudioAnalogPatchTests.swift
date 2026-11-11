import XCTest
@testable import DAWCore

final class StudioAnalogPatchTests: XCTestCase {
    func testParameterIdentifiersAndInitialValuesMatchDSP() throws {
        let synth = try StudioAnalogInstrument(sampleRate: 44_100)
        XCTAssertEqual(StudioAnalogParameter.allCases.count, 21)
        for parameter in StudioAnalogParameter.allCases {
            XCTAssertEqual(synth.parameter(parameter.rawValue), parameter.defaultValue,
                           accuracy: 0.0001, "Default mismatch for \(parameter)")
        }
    }

    func testNativePatchRoundTripAndBackwardCompatibility() throws {
        var track = Track(name: "Analog Lead", type: .instrument)
        track.studioAnalogEnabled = true
        var patch = StudioAnalogPatch()
        patch.set(1_250, for: .filterCutoff)
        patch.set(1, for: .oscillator1Wave)
        patch.set(0.22, for: .amplitudeAttack)
        patch.set(.nan, for: .resonance)
        track.studioAnalogPatch = patch

        let data = try JSONEncoder().encode(track)
        let restored = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(restored.studioAnalogPatch?.value(for: .filterCutoff), 1_250)
        XCTAssertEqual(restored.studioAnalogPatch?.value(for: .oscillator1Wave), 1)
        XCTAssertEqual(restored.studioAnalogPatch?.value(for: .resonance), 0.18)
        let synth = try StudioAnalogInstrument(sampleRate: 44_100)
        synth.apply(try XCTUnwrap(restored.studioAnalogPatch))
        XCTAssertEqual(synth.parameter(6), 1_250)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "studioAnalogPatch")
        let oldTrack = try JSONDecoder().decode(Track.self, from:
                         JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldTrack.studioAnalogPatch)
    }

    func testNormalizedSliderControlsStayWithinNativeRange() {
        for parameter in StudioAnalogParameter.allCases where parameter != .oscillator1Wave && parameter != .oscillator2Wave {
            for fraction in [0.0, 0.05, 0.5, 0.95, 1.0] {
                let value = parameter.value(at: fraction)
                XCTAssertTrue(parameter.valid(value), "\(parameter) produced \(value)")
                XCTAssertEqual(parameter.position(for: value), fraction, accuracy: 0.002)
            }
        }
    }
}
