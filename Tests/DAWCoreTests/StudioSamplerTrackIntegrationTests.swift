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

    func testBadMappingDoesNotAttachAnInstrument() throws {
        var patch = StudioSamplerPatch(zones: [])
        XCTAssertFalse(patch.isValid)
        XCTAssertThrowsError(try StudioSamplerInstrument(sampleRate: 44_100, patch: patch))
        patch = StudioSamplerPatch(sampleURL: URL(fileURLWithPath: "/no/such/file.wav"))
        XCTAssertThrowsError(try StudioSamplerInstrument(sampleRate: 44_100, patch: patch))
    }
}
