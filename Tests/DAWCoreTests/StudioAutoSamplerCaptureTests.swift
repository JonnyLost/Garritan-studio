import XCTest
import AVFoundation
import AudioToolbox
@testable import DAWCore

/// Tests do not assume that a developer or CI Mac has licensed plug-ins.
final class StudioAutoSamplerCaptureTests: XCTestCase {
    func testCoveragePresetsAreBoundedAndProvideVelocityLayers() {
        let modes = StudioAutoSamplerCapture.Coverage.allCases
        XCTAssertEqual(modes.count, 3)
        for mode in modes {
            let options = mode.options
            XCTAssertTrue(options.isValid, "\(mode.title) must be a valid capture plan")
            XCTAssertLessThanOrEqual(options.rootNotes.count * options.velocities.count, 128)
        }
        XCTAssertEqual(StudioAutoSamplerCapture.Coverage.quick.options.velocities.count, 1)
        XCTAssertEqual(StudioAutoSamplerCapture.Coverage.standard.options.velocities.count, 2)
        XCTAssertEqual(StudioAutoSamplerCapture.Coverage.deep.options.velocities.count, 4)
    }

    func testSourceIdentityIsIndependentOfDisplayedText() {
        let one = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0x41424344,
            manufacturer: 0x45464748, name: "Old name", vendor: "Manufacturer")
        let renamed = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0x41424344,
            manufacturer: 0x45464748, name: "New name", vendor: "Manufacturer")
        XCTAssertEqual(one.id, renamed.id)
    }

    func testDiscoveryReturnsRegisteredMusicDeviceComponentsOnly() {
        let results = StudioAutoSamplerCapture.availableSources()
        XCTAssertTrue(results.allSatisfy { $0.type == kAudioUnitType_MusicDevice })
        XCTAssertEqual(Set(results.map(\.id)).count, results.count)
    }

    func testConfiguredStateAcceptsPropertyListsFromStudioPluginHost() throws {
        let example: [String: Any] = [
            "name": "Custom Piano",
            "data": Data([0, 12, 255, 42]),
            "parameters": ["brightness": 0.67, "detune": 0.12]
        ]
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: example, format: .binary, options: 0)
        let restored = try StudioAutoSamplerCapture.validatedConfiguredState(encoded)
        XCTAssertEqual(restored["name"] as? String, "Custom Piano")
        XCTAssertEqual(restored["data"] as? Data, Data([0, 12, 255, 42]))
    }

    func testConfiguredStateRejectsBadOrEmptyDataBeforeLoadingAnyPlugin() async {
        for payload in [Data(), Data([1, 2, 3, 4])] {
            XCTAssertThrowsError(
                try StudioAutoSamplerCapture.validatedConfiguredState(payload))
        }

        let fakeInstrument = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0,
            manufacturer: 0, name: "Fake AU", vendor: "Test")
        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: fakeInstrument, name: "Invalid State",
                configuredState: Data([1, 2, 3, 4]))
            XCTFail("Invalid state should fail before an AU instance is created")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguredState {
            // Expected preflight failure.
        } catch {
            XCTFail("Unexpected preflight error: \(error)")
        }

        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: fakeInstrument, name: "Conflicting Inputs",
                presetNumber: 0, configuredState: Data([1]))
            XCTFail("Cannot select a factory preset and a configured state together")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Expected before instantiation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCaptureRejectsNonInstrumentAndInvalidOptionsWithoutLoadingPlugin() async {
        let effect = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_Effect, subtype: 0, manufacturer: 0,
            name: "Fake effect", vendor: "Test")
        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: effect, name: "Reject this source")
            XCTFail("An Audio Unit effect is not a MIDI instrument")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Expected before attempting plug-in loading or creating any files.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let fakeInstrument = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0,
            manufacturer: 0, name: "Fake AU", vendor: "Test")
        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: fakeInstrument, name: " ",
                options: .init(rootNotes: [], velocities: [100]))
            XCTFail("Invalid options and empty name must be rejected")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
