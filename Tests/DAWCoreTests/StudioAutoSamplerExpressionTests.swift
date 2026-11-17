import XCTest
import AVFoundation
import AudioToolbox
@testable import DAWCore

/// Independent coverage of capture scheduling and native patch mapping.
/// These tests require no third-party plug-in or source sample library.
final class StudioAutoSamplerExpressionTests: XCTestCase {
    func testOrdinaryVelocityCapturePreservesOriginalBehavior() {
        let config = StudioAutoSamplerExpression.Configuration()
        XCTAssertTrue(config.canCaptureLayers([64, 112],
                                              captureReleaseTails: true))
        let point = config.point(for: 64, allLayers: [64, 112])
        XCTAssertEqual(point.mappedVelocity, 64)
        XCTAssertEqual(point.playedVelocity, 64)
        XCTAssertNil(point.sourceCC1)
        XCTAssertNil(point.sourceCC11)
        let original = StudioSamplerPatch(zones: [
            .init(sampleURL: URL(fileURLWithPath: "/tmp/expression.wav"),
                  rootNote: 60)])
        XCTAssertEqual(config.applying(to: original), original)
    }

    func testCapturedCC1PositionsMatchNativeSamplerBandCenters() {
        let config = StudioAutoSamplerExpression.Configuration(
            mode: .cc1Layers, fixedNoteVelocity: 100, sourceCC11: 110)
        XCTAssertTrue(config.canCaptureLayers([64, 112],
                                              captureReleaseTails: false))
        XCTAssertEqual(StudioAutoSamplerExpression.Configuration.cc1Centers(
            for: [64, 112]), [45, 108])
        XCTAssertEqual(StudioAutoSamplerExpression.Configuration.cc1Centers(
            for: [32, 64, 96, 120]), [25, 65, 95, 118])

        let soft = config.point(for: 64, allLayers: [64, 112])
        XCTAssertEqual(soft.mappedVelocity, 64)
        XCTAssertEqual(soft.playedVelocity, 100)
        XCTAssertEqual(soft.sourceCC1, 45)
        XCTAssertEqual(soft.sourceCC11, 110)
        let loud = config.point(for: 112, allLayers: [64, 112])
        XCTAssertEqual(loud.playedVelocity, 100)
        XCTAssertEqual(loud.sourceCC1, 108)

        let patch = StudioSamplerPatch(zones: [
            .init(sampleURL: URL(fileURLWithPath: "/tmp/expression.wav"),
                  rootNote: 60)])
        let mapped = config.applying(to: patch)
        XCTAssertTrue(mapped.isValid)
        XCTAssertEqual(mapped.cc1Crossfade, true)
        XCTAssertEqual(mapped.dynamicsCC1, 96)
        XCTAssertEqual(mapped.expressionCC11, 127)
        XCTAssertNil(patch.cc1Crossfade)
    }

    func testCC11ReferenceIsExplicitAndDoesNotDoubleApplyOnPlayback() {
        let reference = StudioAutoSamplerExpression.Configuration(
            mode: .velocity, sourceCC11: 96)
        let point = reference.point(for: 80, allLayers: [80])
        XCTAssertEqual(point.playedVelocity, 80)
        XCTAssertNil(point.sourceCC1)
        XCTAssertEqual(point.sourceCC11, 96)

        let configuredCC1 = StudioAutoSamplerExpression.Configuration(
            mode: .cc1Layers)
        XCTAssertEqual(configuredCC1.point(for: 112,
            allLayers: [64, 112]).sourceCC11, 127)
        XCTAssertFalse(StudioAutoSamplerExpression.Configuration(
            sourceCC11: 0).isValid)
        XCTAssertFalse(StudioAutoSamplerExpression.Configuration(
            fixedNoteVelocity: 0).isValid)
    }

    func testCC1ReleaseCaptureRequiresMultipleLayersAndRespectsZoneLimit() {
        let config = StudioAutoSamplerExpression.Configuration(mode: .cc1Layers)
        XCTAssertFalse(config.canCaptureLayers([100],
                                               captureReleaseTails: false))
        XCTAssertTrue(config.canCaptureLayers([64, 112],
                                              captureReleaseTails: true))
        XCTAssertTrue(config.canCaptureLayers([32, 64, 96, 120],
                                              captureReleaseTails: false))
        XCTAssertFalse(config.canCaptureLayers(Array(1...9).map(UInt8.init),
                                               captureReleaseTails: false))
    }

    func testOversizedCC1ReleaseConfigurationFailsBeforeLoadingAudioUnit() async {
        let source = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0, manufacturer: 0,
            name: "Not Installed", vendor: "Test")
        let config = StudioAutoSamplerExpression.Configuration(mode: .cc1Layers)
        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: source, name: "Reject oversized release capture",
                options: .init(rootNotes: Array(36...100).map(UInt8.init),
                               velocities: [64, 112]),
                captureReleaseTails: true, expression: config)
            XCTFail("Oversized CC1 release capture must fail before loading the AU")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Expected preflight error; never load the plugin.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: source, name: "Reject single CC1 layer",
                options: .init(rootNotes: [60], velocities: [100]),
                expression: config)
            XCTFail("Single-layer CC1 morphing is not a valid capture")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
