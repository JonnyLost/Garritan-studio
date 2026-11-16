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

    func testNativeSynthRendersAudibleAudioIntoAVAudioEngine() throws {
        // A self-contained offline render exercises the native source-node
        // callback without needing an audio device or a user's MIDI hardware.
        let sampleRate = 44_100.0
        let synth = try StudioAnalogInstrument(sampleRate: sampleRate)
        let format = synth.format
        let engine = AVAudioEngine()
        engine.attach(synth.audioNode)
        engine.connect(synth.audioNode, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 512
        )
        try engine.start()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }

        XCTAssertTrue(synth.noteOn(69, velocity: 100))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
            XCTFail("Could not allocate offline render buffer")
            return
        }
        var maximumPeak: Float = 0
        for _ in 0..<12 {
            let status = try engine.renderOffline(512, to: buffer)
            XCTAssertEqual(status, .success)
            guard let channels = buffer.floatChannelData else {
                XCTFail("Expected two planar Float32 channels")
                return
            }
            for i in 0..<Int(buffer.frameLength) {
                let left = channels[0][i]
                let right = channels[1][i]
                XCTAssertTrue(left.isFinite && right.isFinite)
                maximumPeak = max(maximumPeak, abs(left), abs(right))
            }
        }
        XCTAssertGreaterThan(maximumPeak, 0.01, "The native source node must produce audible samples")
        XCTAssertTrue(synth.noteOff(69))
    }

    func testNativeMIDIExpressionBridgeValidatesMessagesAndChannels() throws {
        let synth = try StudioAnalogInstrument(sampleRate: 44_100)
        XCTAssertTrue(synth.noteOn(69, velocity: 100, channel: 2, frameOffset: 64))
        XCTAssertTrue(synth.pitchBend(16_383, channel: 2))
        XCTAssertTrue(synth.controller(1, value: 127, channel: 2))
        XCTAssertTrue(synth.controller(64, value: 127, channel: 2))
        XCTAssertTrue(synth.noteOff(69, channel: 2, frameOffset: 128))
        XCTAssertTrue(synth.controller(64, value: 0, channel: 2))
        XCTAssertFalse(synth.pitchBend(16_384, channel: 2))
        XCTAssertFalse(synth.midiMessage(status: 0xF0, data1: 0, data2: 0))
        XCTAssertFalse(synth.midiMessage(status: 0x90, data1: 60,
                                        data2: 120, frameOffset: 65_536))
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
