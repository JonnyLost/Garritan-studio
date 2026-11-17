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

    func testDefaultPlansPreserveQuickStandardAndDeepCaptureNotes() {
        let expected: [(StudioAutoSamplerCapture.Coverage, [UInt8], [UInt8])] = [
            (.quick, [48, 60, 72], [100]),
            (.standard, [36, 48, 60, 72, 84], [64, 112]),
            (.deep, [36, 42, 48, 54, 60, 66, 72, 78, 84, 90, 96],
             [32, 64, 96, 120])
        ]
        for (coverage, notes, velocities) in expected {
            let plan = StudioAutoSamplerCapture.SamplingPlan(coverage: coverage)
            XCTAssertTrue(plan.isValid)
            XCTAssertEqual(plan.rootNotes, notes)
            XCTAssertEqual(plan.velocities, velocities)
            XCTAssertEqual(plan.midiChannel, 1)
            XCTAssertEqual(plan.options().rootNotes, notes)
        }
    }

    func testMIDIChannelRangeIsOneToSixteen() {
        for channel: UInt8 in 1...16 {
            let plan = StudioAutoSamplerCapture.SamplingPlan(
                coverage: .standard, midiChannel: channel)
            XCTAssertTrue(plan.isValid)
        }
        XCTAssertFalse(StudioAutoSamplerCapture.SamplingPlan(
            midiChannel: 0).isValid)
        XCTAssertFalse(StudioAutoSamplerCapture.SamplingPlan(
            midiChannel: 17).isValid)
    }

    func testCustomRangeIncludesRequestedHighNoteAndBoundsZoneCount() {
        let plan = StudioAutoSamplerCapture.SamplingPlan(
            coverage: .standard, lowestNote: 50, highestNote: 62,
            semitoneStep: 5, midiChannel: 4, limitPlaybackToRange: true)
        XCTAssertEqual(plan.rootNotes, [50, 55, 60, 62])
        XCTAssertEqual(plan.sampleCount, 8)
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.options().velocities, [64, 112])

        let single = StudioAutoSamplerCapture.SamplingPlan(
            coverage: .deep, lowestNote: 60, highestNote: 60,
            semitoneStep: 12)
        XCTAssertTrue(single.isValid)
        XCTAssertEqual(single.rootNotes, [60])

        let overflowing = StudioAutoSamplerCapture.SamplingPlan(
            coverage: .deep, lowestNote: 0, highestNote: 127,
            semitoneStep: 1)
        XCTAssertEqual(overflowing.rootNotes.count, 128)
        XCTAssertEqual(overflowing.sampleCount, 512)
        XCTAssertFalse(overflowing.isValid)

        XCTAssertFalse(StudioAutoSamplerCapture.SamplingPlan(
            lowestNote: 90, highestNote: 40).isValid)
        XCTAssertFalse(StudioAutoSamplerCapture.SamplingPlan(
            semitoneStep: 0).isValid)
        XCTAssertFalse(StudioAutoSamplerCapture.SamplingPlan(
            highestNote: 128).isValid)
    }

    func testCustomPlaybackRangeDoesNotChangeExistingFactoryMap() {
        let url = URL(fileURLWithPath: "/tmp/studio-auto-sampler-test.wav")
        let zoneA = StudioSamplerZone(
            sampleURL: url, rootNote: 48, lowestNote: 0, highestNote: 60)
        let zoneB = StudioSamplerZone(
            sampleURL: url, rootNote: 72, lowestNote: 61, highestNote: 127)
        let original = StudioSamplerPatch(zones: [zoneA, zoneB])
        let plan = StudioAutoSamplerCapture.SamplingPlan(
            coverage: .standard, lowestNote: 48, highestNote: 72,
            semitoneStep: 12, limitPlaybackToRange: true)
        let clamped = plan.applyingPlaybackRange(to: original)
        XCTAssertTrue(clamped.isValid)
        XCTAssertEqual(clamped.zones.map(\.lowestNote), [48, 61])
        XCTAssertEqual(clamped.zones.map(\.highestNote), [60, 72])
        XCTAssertEqual(original.zones.map(\.lowestNote), [0, 61])
        XCTAssertEqual(original.zones.map(\.highestNote), [60, 127])
        let unrestricted = StudioAutoSamplerCapture.SamplingPlan(
            coverage: .standard, lowestNote: 48, highestNote: 72,
            semitoneStep: 12, limitPlaybackToRange: false)
        XCTAssertEqual(unrestricted.applyingPlaybackRange(to: original), original)
    }

    func testCaptureRejectsInvalidCapturePlansBeforeCreatingPlugin() async {
        let fake = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0,
            manufacturer: 0, name: "Fake source", vendor: "Test")
        let plans: [StudioAutoSamplerCapture.SamplingPlan] = [
            .init(midiChannel: 0),
            .init(midiChannel: 17),
            .init(lowestNote: 90, highestNote: 40),
            .init(coverage: .deep, lowestNote: 0, highestNote: 127,
                  semitoneStep: 1)
        ]
        for plan in plans {
            do {
                _ = try await StudioAutoSamplerCapture.capture(
                    source: fake, name: "Invalid configuration", plan: plan)
                XCTFail("Capture should fail before attempting to load any AU")
            } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
                // Expected.
            } catch {
                XCTFail("Unexpected preflight error: \(error)")
            }
        }
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

    func testReleaseZoneLimitRejectsOversizedPlanBeforePluginInstantiation() async {
        let source = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice,
            subtype: 0, manufacturer: 0, name: "No Installed AU",
            vendor: "Test")
        // The normal 128-zone factory accepts 65 distinct held notes, but
        // pairing them with release-trigger recordings could exceed 128.
        let options = StudioSynthSamplerCapture.Options(
            rootNotes: (0...64).map { UInt8($0) },
            velocities: [100])
        XCTAssertTrue(options.isValid)
        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: source, name: "Reject oversized release capture",
                options: options, captureReleaseTails: true)
            XCTFail("Must fail without instantiating an Audio Unit")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Correct early preflight validation.
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
