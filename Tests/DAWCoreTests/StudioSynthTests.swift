import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioSynthTests: XCTestCase {
    func testPatchRoundTripAndIndividualModes() throws {
        let hybrid = StudioSynthPatch()
        XCTAssertTrue(hybrid.validate())
        XCTAssertTrue(hybrid.isHybrid)
        XCTAssertEqual(hybrid.layers.map(\.engine), [.analog, .fm])
        let data = try JSONEncoder().encode(hybrid)
        XCTAssertEqual(try JSONDecoder().decode(StudioSynthPatch.self, from: data), hybrid)
        for engine in StudioSynthEngine.allCases {
            let sound = StudioSynthPatch.individual(engine)
            XCTAssertTrue(sound.validate())
            XCTAssertFalse(sound.isHybrid)
            XCTAssertEqual(sound.layers.first?.engine, engine)
        }
    }

    func testLayerValidationPreventsCorruptGraphsAndParameters() {
        var patch = StudioSynthPatch()
        patch.layers[1].id = patch.layers[0].id
        XCTAssertFalse(patch.validate())
        patch = StudioSynthPatch()
        patch.layers[0].enabled = false
        patch.layers[1].enabled = false
        XCTAssertFalse(patch.validate())
        patch = StudioSynthPatch()
        patch.layers[0].gain = .nan
        XCTAssertFalse(patch.validate())
        patch = StudioSynthPatch()
        patch.layers[0].pan = 1.1
        XCTAssertFalse(patch.validate())
        XCTAssertFalse(StudioSynthPatch(layers: []).validate())
        patch = StudioSynthPatch()
        patch.layers += (0..<3).map { _ in StudioSynthLayer(engine: .analog) }
        XCTAssertFalse(patch.validate())
        patch = StudioSynthPatch()
        var broken = StudioFMPatch()
        broken.values["1"] = 42
        patch.layers[1].fmPatch = broken
        XCTAssertFalse(patch.validate())
        XCTAssertThrowsError(try StudioSynthInstrument(sampleRate: 44_100, patch: patch))
    }

    func testTrackPersistencePreservesLegacyProjectDecode() throws {
        var track = Track(name: "Hybrid", type: .instrument)
        track.studioSynthEnabled = true
        track.studioSynthPatch = StudioSynthPatch()
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded.studioSynthEnabled, true)
        XCTAssertEqual(decoded.studioSynthPatch, track.studioSynthPatch)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "studioSynthEnabled")
        old.removeValue(forKey: "studioSynthPatch")
        let legacy = try JSONDecoder().decode(
            Track.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.studioSynthEnabled)
        XCTAssertNil(legacy.studioSynthPatch)
    }

    func testHybridMIDIAndPerLayerControls() throws {
        let patch = StudioSynthPatch()
        let hybrid = try StudioSynthInstrument(sampleRate: 44_100, patch: patch)
        XCTAssertEqual(hybrid.auxiliaryNodes.count, 4)
        XCTAssertTrue(hybrid.noteOn(69, velocity: 110, channel: 2))
        XCTAssertTrue(hybrid.controller(1, value: 127, channel: 2))
        XCTAssertTrue(hybrid.controller(64, value: 127, channel: 2))
        XCTAssertTrue(hybrid.pitchBend(16_383, channel: 2))
        XCTAssertTrue(hybrid.noteOff(69, channel: 2))
        XCTAssertTrue(hybrid.allNotesOff())
        XCTAssertFalse(hybrid.pitchBend(16_384))
        XCTAssertFalse(hybrid.midiMessage(status: 0xF0, data1: 0, data2: 0))
        let analog = patch.layers[0].id, fm = patch.layers[1].id
        XCTAssertTrue(hybrid.setAnalogParameter(id: analog, parameter: .filterCutoff, value: 3_000))
        XCTAssertTrue(hybrid.setFMParameter(id: fm, parameter: .feedback, value: 0.4))
        XCTAssertFalse(hybrid.setFMParameter(id: analog, parameter: .feedback, value: 0.4))
        XCTAssertTrue(hybrid.setMix(id: fm, gain: 0.4, pan: -0.3))
        XCTAssertFalse(hybrid.setMix(id: fm, gain: 2.0, pan: 0))
        var one = patch
        one.layers[1].enabled = false
        let solo = try StudioSynthInstrument(sampleRate: 44_100, patch: one)
        XCTAssertEqual(solo.auxiliaryNodes.count, 2)
    }

    func testHybridRendersAudioThroughAVAudioEngineOffline() throws {
        let rate = 44_100.0
        let synth = try StudioSynthInstrument(sampleRate: rate, patch: StudioSynthPatch())
        let engine = AVAudioEngine()
        try synth.attach(to: engine, destination: engine.mainMixerNode, sampleRate: rate)
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 512)
        try engine.start()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }
        XCTAssertTrue(synth.noteOn(69, velocity: 110))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: 512))
        var peak: Float = 0
        for _ in 0..<12 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                let l = samples[0][i], r = samples[1][i]
                XCTAssertTrue(l.isFinite && r.isFinite)
                peak = max(peak, abs(l), abs(r))
            }
        }
        XCTAssertGreaterThan(peak, 0.005)
        XCTAssertTrue(synth.allNotesOff())
    }
}
