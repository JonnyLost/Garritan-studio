import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioFMTrackIntegrationTests: XCTestCase {
    func testNativeFMInstrumentUsesStereoSourceAndValidatesParameters() throws {
        let synth = try StudioFMInstrument(sampleRate: 44_100)
        XCTAssertTrue(synth.audioNode is AVAudioSourceNode)
        XCTAssertEqual(synth.format.channelCount, 2)
        XCTAssertFalse(synth.format.isInterleaved)
        XCTAssertEqual(synth.format.sampleRate, 44_100)

        XCTAssertTrue(synth.noteOn(69, velocity: 100, channel: 2))
        XCTAssertTrue(synth.noteOff(69, channel: 2))
        XCTAssertTrue(synth.pitchBend(16_383, channel: 2))
        XCTAssertFalse(synth.pitchBend(16_384, channel: 2))
        XCTAssertTrue(synth.controller(64, value: 127, channel: 2))
        XCTAssertTrue(synth.controller(64, value: 0, channel: 2))
        XCTAssertTrue(synth.controller(1, value: 127, channel: 2))
        XCTAssertFalse(synth.midiMessage(status: 0xF0, data1: 0, data2: 0))
        XCTAssertTrue(synth.allNotesOff())
    }

    func testNativeFMGeneratesAudibleAudioThroughAVAudioEngine() throws {
        let synth = try StudioFMInstrument(sampleRate: 44_100)
        let engine = AVAudioEngine()
        engine.attach(synth.audioNode)
        engine.connect(synth.audioNode, to: engine.mainMixerNode, format: synth.format)
        try engine.enableManualRenderingMode(.offline, format: synth.format,
                                             maximumFrameCount: 512)
        try engine.start()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }

        XCTAssertTrue(synth.noteOn(69, velocity: 115))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: synth.format, frameCapacity: 512) else {
            XCTFail("No offline audio buffer")
            return
        }
        var peak: Float = 0
        for _ in 0..<12 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            guard let data = buffer.floatChannelData else {
                XCTFail("Expected deinterleaved stereo Float32 buffers")
                return
            }
            for index in 0..<Int(buffer.frameLength) {
                let a = data[0][index]
                let b = data[1][index]
                XCTAssertTrue(a.isFinite && b.isFinite)
                peak = max(peak, abs(a), abs(b))
            }
        }
        XCTAssertGreaterThan(peak, 0.01)
        XCTAssertTrue(synth.noteOff(69))
    }

    func testParameterDefaultsAndVersionedPatchRoundTrip() throws {
        let synth = try StudioFMInstrument(sampleRate: 44_100)
        XCTAssertEqual(StudioFMParameter.allCases.count, 32)
        for parameter in StudioFMParameter.allCases {
            XCTAssertEqual(synth.parameter(parameter), parameter.defaultValue,
                           accuracy: 0.0001, "\(parameter)")
        }
        var patch = StudioFMPatch()
        patch.set(2, for: .algorithm)
        patch.set(3.5, for: .op2Ratio)
        patch.set(0.8, for: .op4Level)
        patch.set(0.7, for: .feedback)
        patch.set(0.85, for: .velocityBrightness)
        patch.set(1, for: .modTarget)
        patch.set(0.75, for: .modDepth)
        patch.set(6.3, for: .modRate)
        patch.set(.nan, for: .op1Level)
        XCTAssertEqual(patch.value(for: .op1Level), StudioFMParameter.op1Level.defaultValue)
        XCTAssertTrue(patch.validate())
        try synth.apply(patch)
        XCTAssertEqual(synth.parameter(.op2Ratio), 3.5)
        XCTAssertEqual(synth.parameter(.algorithm), 2)
        XCTAssertEqual(synth.parameter(.velocityBrightness), 0.85, accuracy: 0.0001)
        XCTAssertEqual(synth.parameter(.modTarget), 1)
        XCTAssertEqual(synth.parameter(.modDepth), 0.75, accuracy: 0.0001)
        XCTAssertEqual(synth.parameter(.modRate), 6.3, accuracy: 0.0001)

        var track = Track(name: "FM Electric Piano", type: .instrument)
        track.studioFMEnabled = true
        track.studioAnalogEnabled = false
        track.studioFMPatch = patch
        let stored = try JSONEncoder().encode(track)
        let restored = try JSONDecoder().decode(Track.self, from: stored)
        XCTAssertEqual(restored.studioFMEnabled, true)
        XCTAssertEqual(restored.studioAnalogEnabled, false)
        XCTAssertEqual(restored.studioFMPatch, patch)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        legacy.removeValue(forKey: "studioFMEnabled")
        legacy.removeValue(forKey: "studioFMPatch")
        let oldTrack = try JSONDecoder().decode(Track.self, from:
                                JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldTrack.studioFMEnabled)
        XCTAssertNil(oldTrack.studioFMPatch)
        var invalid = StudioFMPatch()
        invalid.values["999"] = 0.5
        XCTAssertFalse(invalid.validate())
        XCTAssertThrowsError(try synth.apply(invalid))
    }

    func testOperatorControlsMatchDSPAndSliderRanges() {
        for index in 0..<4 {
            for control in StudioFMOperatorControl.allCases {
                let parameter = StudioFMParameter.op(index, control)
                XCTAssertNotNil(parameter)
                XCTAssertEqual(parameter?.operatorIndex, index)
                XCTAssertEqual(parameter?.operatorControl, control)
            }
        }
        XCTAssertNil(StudioFMParameter.op(-1, .ratio))
        XCTAssertNil(StudioFMParameter.op(4, .level))
        for parameter in StudioFMParameter.allCases where parameter != .algorithm && parameter != .modTarget {
            for fraction in [0.0, 0.1, 0.5, 0.9, 1.0] {
                let value = parameter.value(at: fraction)
                XCTAssertTrue(parameter.valid(value), "\(parameter): \(value)")
                XCTAssertEqual(parameter.position(for: value), fraction, accuracy: 0.002)
            }
        }
    }

    func testFMModWheelDestinationIsDiscreteAndNewControlsPersist() throws {
        let synth = try StudioFMInstrument(sampleRate: 44_100)
        XCTAssertTrue(StudioFMParameter.velocityBrightness.valid(0))
        XCTAssertTrue(StudioFMParameter.velocityBrightness.valid(1))
        XCTAssertFalse(StudioFMParameter.velocityBrightness.valid(1.1))
        XCTAssertFalse(StudioFMParameter.modTarget.valid(0.5))
        XCTAssertFalse(StudioFMParameter.modRate.valid(0))
        XCTAssertFalse(StudioFMParameter.modRate.valid(20.1))
        XCTAssertNil(StudioFMParameter.velocityBrightness.operatorIndex)
        XCTAssertNil(StudioFMParameter.modDepth.operatorControl)
        var saved = StudioFMPatch()
        saved.set(0.63, for: .velocityBrightness)
        saved.set(1, for: .modTarget)
        saved.set(0.75, for: .modDepth)
        saved.set(5.4, for: .modRate)
        let decoded = try JSONDecoder().decode(StudioFMPatch.self,
                                               from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        try synth.apply(decoded)
        XCTAssertEqual(synth.parameter(.velocityBrightness), 0.63, accuracy: 0.001)
        XCTAssertEqual(synth.parameter(.modTarget), 1)
        XCTAssertEqual(synth.parameter(.modRate), 5.4, accuracy: 0.001)
    }

    func testTrackInstrumentFMUsesSameGenericMidiBridge() throws {
        let synth = try StudioFMInstrument(sampleRate: 44_100)
        let instrument = TrackInstrument.studioFM(synth)
        XCTAssertTrue(instrument.audioNode === synth.audioNode)
        instrument.startNote(60, velocity: 80, channel: 0)
        instrument.sendPitchBend(8_192, channel: 0)
        instrument.sendController(64, value: 127, channel: 0)
        instrument.sendController(1, value: 100, channel: 0)
        instrument.stopNote(60, channel: 0)
        instrument.sendController(64, value: 0, channel: 0)
        XCTAssertTrue(synth.allNotesOff())
    }
}
