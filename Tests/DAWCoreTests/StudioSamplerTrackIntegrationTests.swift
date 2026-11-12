import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioSamplerTrackIntegrationTests: XCTestCase {
    private func makeSample() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-sampler-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let frames: AVAudioFrameCount = 8_820
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let value = Float(sin(Double(i) * 2 * .pi * 440 / 44_100))
            data[0][i] = value
            data[1][i] = value * 0.5
        }
        do {
            let output = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            try output.write(from: buffer)
        }
        return url
    }

    func testSamplerRendersOriginalStereoAudioWithoutPlugin() throws {
        let url = try makeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let patch = StudioSamplerPatch(sampleURL: url, rootNote: 69)
        let sampler = try StudioSamplerInstrument(sampleRate: 44_100, patch: patch)
        XCTAssertEqual(sampler.format.channelCount, 2)
        XCTAssertFalse(sampler.format.isInterleaved)
        let engine = AVAudioEngine()
        engine.attach(sampler.audioNode)
        engine.connect(sampler.audioNode, to: engine.mainMixerNode, format: sampler.format)
        try engine.enableManualRenderingMode(
            .offline, format: sampler.format, maximumFrameCount: 512
        )
        try engine.start()
        defer { engine.stop(); engine.disableManualRenderingMode() }
        XCTAssertTrue(sampler.noteOn(69, velocity: 127, channel: 0))
        let output = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sampler.format, frameCapacity: 512)
        )
        var peakL: Float = 0
        var peakR: Float = 0
        for _ in 0..<4 {
            let status = try engine.renderOffline(512, to: output)
            XCTAssertEqual(status, .success)
            let data = try XCTUnwrap(output.floatChannelData)
            for i in 0..<Int(output.frameLength) {
                XCTAssertTrue(data[0][i].isFinite)
                XCTAssertTrue(data[1][i].isFinite)
                peakL = max(peakL, abs(data[0][i]))
                peakR = max(peakR, abs(data[1][i]))
            }
        }
        XCTAssertGreaterThan(peakL, 0.01)
        XCTAssertGreaterThan(peakR, 0.001)
        XCTAssertTrue(sampler.noteOff(69, channel: 0))
        XCTAssertTrue(sampler.allNotesOff())
    }

    func testSamplerPatchSurvivesSavingAndOldTrackDecodes() throws {
        var track = Track(name: "Sampled instrument", type: .instrument)
        let url = URL(fileURLWithPath: "/tmp/studio-sample.wav")
        var patch = StudioSamplerPatch(sampleURL: url)
        patch.instrumentKind = .soloViolin
        patch.cc1Crossfade = true
        patch.dynamicsCC1 = 68
        patch.expressionCC11 = 92
        track.studioSamplerPatch = patch
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded.studioSamplerPatch, track.studioSamplerPatch)
        XCTAssertNil(decoded.instrumentSlot)
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldJSON.removeValue(forKey: "studioSamplerPatch")
        let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
        XCTAssertNil(try JSONDecoder().decode(Track.self, from: oldData).studioSamplerPatch)
    }

    func testLegacySamplerPatchDefaultsToGeneralFaceAndDiscreteLayers() throws {
        let oldPatch = StudioSamplerPatch(
            sampleURL: URL(fileURLWithPath: "/tmp/original-piano.wav")
        )
        let encoded = try JSONEncoder().encode(oldPatch)
        let decoded = try JSONDecoder().decode(StudioSamplerPatch.self, from: encoded)
        XCTAssertEqual(decoded.presentation, .general)
        XCTAssertNil(decoded.cc1Crossfade)
        XCTAssertNil(decoded.dynamicsCC1)
        XCTAssertNil(decoded.expressionCC11)
    }

    func testADSRAndLoopMarkersPersistThroughTrackRoundTrip() throws {
        var patch = StudioSamplerPatch(
            sampleURL: URL(fileURLWithPath: "/tmp/test-sustain.wav"),
            rootNote: 60
        )
        patch.zones[0].loopStartFrame = 256
        patch.zones[0].loopEndFrame = 2048
        patch.zones[0].loopCrossfadeFrames = 128
        patch.envelope = StudioSamplerEnvelope(
            attackSeconds: 0.12, decaySeconds: 0.18,
            sustainLevel: 0.72, releaseSeconds: 0.63
        )
        XCTAssertTrue(patch.isValid)
        var track = Track(name: "Sustain Loop", type: .instrument)
        track.studioSamplerPatch = patch
        let restored = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track)
        )
        XCTAssertEqual(restored.studioSamplerPatch, patch)
        XCTAssertTrue(restored.studioSamplerPatch?.zones[0].hasSustainLoop == true)

        patch.zones[0].loopCrossfadeFrames = 1000
        XCTAssertFalse(patch.isValid)
        patch.zones[0].loopCrossfadeFrames = 128
        patch.envelope?.sustainLevel = 2
        XCTAssertFalse(patch.isValid)
    }

    func testLoopContinuesAfterRecordingEndsUntilNoteOff() throws {
        let url = try makeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        var patch = StudioSamplerPatch(sampleURL: url, rootNote: 69)
        patch.zones[0].loopStartFrame = 1_500
        patch.zones[0].loopEndFrame = 6_000
        patch.zones[0].loopCrossfadeFrames = 128
        patch.envelope = StudioSamplerEnvelope(
            attackSeconds: 0.005, decaySeconds: 0.01,
            sustainLevel: 1, releaseSeconds: 0.02
        )
        let sampler = try StudioSamplerInstrument(sampleRate: 44_100, patch: patch)
        let engine = AVAudioEngine()
        engine.attach(sampler.audioNode)
        engine.connect(sampler.audioNode, to: engine.mainMixerNode, format: sampler.format)
        try engine.enableManualRenderingMode(
            .offline, format: sampler.format, maximumFrameCount: 512
        )
        try engine.start()
        defer { engine.stop(); engine.disableManualRenderingMode() }
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sampler.format, frameCapacity: 512)
        )
        XCTAssertTrue(sampler.noteOn(69, velocity: 110, channel: 0))
        // 60 buffers = 0.70s, well beyond the original 0.20s recording.
        var latePeak: Float = 0
        for index in 0..<60 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            if index >= 55, let data = buffer.floatChannelData {
                for sample in 0..<Int(buffer.frameLength) {
                    latePeak = max(latePeak, abs(data[0][sample]))
                }
            }
        }
        XCTAssertGreaterThan(latePeak, 0.01)
        XCTAssertTrue(sampler.noteOff(69, channel: 0))
        for _ in 0..<12 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
        }
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(buffer.frameLength) {
            XCTAssertLessThan(abs(data[0][i]), 0.0001)
        }
    }

    func testLoopCannotExtendBeyondSourceRecording() throws {
        let url = try makeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        var patch = StudioSamplerPatch(sampleURL: url, rootNote: 69)
        patch.zones[0].loopStartFrame = 2_000
        patch.zones[0].loopEndFrame = 12_000
        patch.zones[0].loopCrossfadeFrames = 128
        XCTAssertTrue(patch.isValid) // Structural validation only
        XCTAssertThrowsError(
            try StudioSamplerInstrument(sampleRate: 44_100, patch: patch)
        ) { error in
            guard case StudioSamplerError.invalidLoop = error else {
                XCTFail("Expected invalid source loop position, got \(error)")
                return
            }
        }
    }

    func testTrimAndWaveformPersistAndAnalyzeOriginalFile() throws {
        let url = try makeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let analyzed = try StudioSamplerWaveformAnalyzer.analyze(url: url, columns: 100)
        XCTAssertEqual(analyzed.totalFrames, 8_820)
        XCTAssertEqual(analyzed.peaks.count, 100)
        XCTAssertEqual(analyzed.sampleRate, 44_100, accuracy: 0.01)
        XCTAssertGreaterThan(analyzed.peaks.max() ?? 0, 0.9)

        var patch = StudioSamplerPatch(sampleURL: url, rootNote: 69)
        patch.zones[0].trimStartFrame = 2_000
        patch.zones[0].trimEndFrame = 4_000
        XCTAssertTrue(patch.isValid)
        var track = Track(name: "Edited Sample", type: .instrument)
        track.studioSamplerPatch = patch
        let restored = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track)
        )
        XCTAssertEqual(restored.studioSamplerPatch?.zones[0].trimStartFrame, 2_000)
        XCTAssertEqual(restored.studioSamplerPatch?.zones[0].trimEndFrame, 4_000)
        let sampler = try StudioSamplerInstrument(sampleRate: 44_100, patch: patch)
        let engine = AVAudioEngine()
        engine.attach(sampler.audioNode)
        engine.connect(sampler.audioNode, to: engine.mainMixerNode, format: sampler.format)
        try engine.enableManualRenderingMode(
            .offline, format: sampler.format, maximumFrameCount: 512
        )
        try engine.start()
        defer { engine.stop(); engine.disableManualRenderingMode() }
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sampler.format, frameCapacity: 512)
        )
        XCTAssertTrue(sampler.noteOn(69, velocity: 127, channel: 0))
        var peak: Float = 0
        for _ in 0..<5 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            if let data = buffer.floatChannelData {
                for i in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(data[0][i]))
                }
            }
        }
        XCTAssertGreaterThan(peak, 0.01)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        XCTAssertLessThan(abs(channel[511]), 0.0001)
    }

    func testInvalidTrimAndLoopConflictAreRejected() throws {
        var zone = StudioSamplerZone(
            sampleURL: URL(fileURLWithPath: "/tmp/original.wav")
        )
        zone.trimStartFrame = 200
        zone.trimEndFrame = 100
        XCTAssertFalse(zone.isValid)
        zone.trimEndFrame = 600
        zone.loopStartFrame = 120
        zone.loopEndFrame = 400
        XCTAssertFalse(zone.isValid)
        zone.loopStartFrame = 250
        XCTAssertTrue(zone.isValid)
        zone.trimEndFrame = 300
        XCTAssertFalse(zone.isValid)
    }

    func testBadMappingDoesNotAttachAnInstrument() throws {
        var patch = StudioSamplerPatch(zones: [])
        XCTAssertFalse(patch.isValid)
        XCTAssertThrowsError(try StudioSamplerInstrument(sampleRate: 44_100, patch: patch))
        patch = StudioSamplerPatch(sampleURL: URL(fileURLWithPath: "/no/such/file.wav"))
        XCTAssertThrowsError(try StudioSamplerInstrument(sampleRate: 44_100, patch: patch))
    }
}
