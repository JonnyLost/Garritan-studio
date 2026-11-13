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

    func testBoundedDiskSamplePagesAreAccurateAndDoNotPreloadEntireFile() throws {
        let url = try makeSample()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try StudioSamplerDiskChunkReader(url: url)
        XCTAssertEqual(reader.frameCount, 8_820)
        XCTAssertEqual(reader.channels, 2)
        XCTAssertEqual(reader.sampleRate, 44_100, accuracy: 0.01)
        XCTAssertEqual(StudioSamplerStreamBudget.attackFrames(sampleRate: 44_100),
                       11_025)
        XCTAssertEqual(StudioSamplerStreamBudget.readAheadBytes(voices: 32),
                       4_194_304)

        let first = try reader.readPage(startFrame: 0, requestedFrames: 512)
        XCTAssertEqual(first.frameCount, 512)
        XCTAssertEqual(first.left.count, 512)
        XCTAssertEqual(first.right.count, 512)
        XCTAssertEqual(first.startFrame, 0)
        XCTAssertEqual(first.left[100],
                       Float(sin(Double(100) * 2 * .pi * 440 / 44_100)),
                       accuracy: 0.001)
        XCTAssertEqual(first.right[100], first.left[100] * 0.5,
                       accuracy: 0.001)

        // Random seek and short final page, both decoded off the audio thread.
        let direct = try reader.withPage(
            startFrame: 512, requestedFrames: 128
        ) { left, right, frameCount in
            (frameCount, left[25], right?[25] ?? 0)
        }
        XCTAssertEqual(direct.0, 128)
        XCTAssertEqual(direct.2, direct.1 * 0.5, accuracy: 0.001)

        let nearEnd = try reader.readPage(startFrame: 8_700, requestedFrames: 4_096)
        XCTAssertEqual(nearEnd.frameCount, 120)
        XCTAssertEqual(nearEnd.startFrame, 8_700)
        let middle = try reader.readPage(startFrame: 2_000, requestedFrames: 128)
        XCTAssertEqual(middle.frameCount, 128)
        XCTAssertEqual(middle.left[0],
                       Float(sin(Double(2_000) * 2 * .pi * 440 / 44_100)),
                       accuracy: 0.001)
        XCTAssertThrowsError(try reader.readPage(startFrame: 8_820))
        XCTAssertThrowsError(try reader.readPage(startFrame: -1))
        XCTAssertThrowsError(try reader.readPage(startFrame: 10, requestedFrames: 20_000))
        XCTAssertThrowsError(try reader.readPage(startFrame: 10, requestedFrames: 0))
    }

    func testLongSampleStreamsThroughNativeOfflineEngine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-stream-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let frames: AVAudioFrameCount = 176_400 // four-second recording
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let pcm = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let sample = Float(sin(Double(i) * .pi * 2 * 220 / 44_100))
            pcm[0][i] = sample
            pcm[1][i] = -sample * 0.5
        }
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            try file.write(from: buffer)
        }
        let sampler = try StudioSamplerInstrument(
            sampleRate: 44_100,
            patch: StudioSamplerPatch(sampleURL: url, rootNote: 69)
        )
        XCTAssertTrue(sampler.isUsingDiskStreaming)

        let engine = AVAudioEngine()
        engine.attach(sampler.audioNode)
        engine.connect(sampler.audioNode, to: engine.mainMixerNode, format: sampler.format)
        try engine.enableManualRenderingMode(
            .offline, format: sampler.format, maximumFrameCount: 512
        )
        try engine.start()
        defer { engine.stop(); engine.disableManualRenderingMode() }
        let output = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sampler.format, frameCapacity: 512)
        )
        XCTAssertTrue(sampler.noteOn(69, velocity: 127, channel: 0))
        var latePeak: Float = 0
        for block in 0..<150 {
            XCTAssertEqual(try engine.renderOffline(512, to: output), .success)
            if block >= 100 {
                let channels = try XCTUnwrap(output.floatChannelData)
                for frame in 0..<Int(output.frameLength) {
                    XCTAssertTrue(channels[0][frame].isFinite)
                    XCTAssertTrue(channels[1][frame].isFinite)
                    latePeak = max(latePeak, abs(channels[0][frame]))
                }
            }
            // The worker must be scheduled as an independent background
            // producer. Offline mode otherwise races through PCM far faster
            // than realtime playback could.
            Thread.sleep(forTimeInterval: 0.003)
        }
        XCTAssertGreaterThan(latePeak, 0.01)
        XCTAssertTrue(sampler.noteOff(69, channel: 0))
    }

    func testEmptySamplerSelectionPersistsWithoutPretendingItCanPlay() throws {
        // Opening the editor does not need a sample, a sampler audio node,
        // or a file picker. It must survive track JSON and project reopen.
        let empty = StudioSamplerPatch(zones: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.isValid) // no audio-zone loader can run yet

        var track = Track(name: "Empty Sampler", type: .instrument)
        track.studioSamplerPatch = empty
        let restored = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track)
        )
        XCTAssertNotNil(restored.studioSamplerPatch)
        XCTAssertTrue(restored.studioSamplerPatch?.isEmpty == true)
        XCTAssertNil(restored.instrumentSlot)
        XCTAssertNil(restored.studioAnalogEnabled)

        // Existing instrument mappings still require valid sample zones.
        let populated = StudioSamplerPatch(
            sampleURL: URL(fileURLWithPath: "/tmp/violin.wav"), rootNote: 60
        )
        XCTAssertFalse(populated.isEmpty)
        XCTAssertTrue(populated.isValid)
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

    func testLoopFinderSuggestsMarkersWithoutEditingTheRecording() throws {
        let url = try makeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let suggestion = try StudioSamplerLoopFinder.suggest(
            url: url, trimStart: 400, trimEnd: 8000
        )
        XCTAssertGreaterThan(suggestion.startFrame, 400)
        XCTAssertLessThan(suggestion.startFrame, suggestion.endFrame)
        XCTAssertLessThan(suggestion.endFrame, 8000)
        XCTAssertLessThanOrEqual(
            suggestion.crossfadeFrames,
            (suggestion.endFrame - suggestion.startFrame) / 2
        )
        XCTAssertLessThan(suggestion.mismatchScore, 0.50)
        XCTAssertEqual(original, try Data(contentsOf: url))
    }

    func testArticulationsAndSourceFadesPersistAndValidate() throws {
        let url = URL(fileURLWithPath: "/tmp/owned-violin.wav")
        var patch = StudioSamplerPatch(sampleURL: url, rootNote: 69)
        var staccato = StudioSamplerZone(
            sampleURL: url, rootNote: 69, lowestNote: 60, highestNote: 88
        )
        staccato.articulationID = 1
        staccato.trimStartFrame = 100
        staccato.trimEndFrame = 2000
        staccato.fadeInFrames = 180
        staccato.fadeOutFrames = 270
        patch.zones.append(staccato)
        patch.articulations = [
            StudioSamplerArticulation(
                id: 1, name: "Staccato", keyswitchNote: 24
            )
        ]
        patch.selectedArticulationID = 1
        patch.defaultKeyswitchNote = 23
        XCTAssertTrue(patch.isValid)
        var track = Track(name: "Expressive Violin", type: .instrument)
        track.studioSamplerPatch = patch
        let loaded = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track)
        )
        XCTAssertEqual(loaded.studioSamplerPatch, patch)
        patch.zones[1].fadeInFrames = 1800
        XCTAssertFalse(patch.isValid)
        patch.zones[1].fadeInFrames = 180
        patch.articulations?.append(StudioSamplerArticulation(
            id: 2, name: "Pizzicato", keyswitchNote: 24
        ))
        XCTAssertFalse(patch.isValid)
        patch.articulations?[1].keyswitchNote = 25
        XCTAssertTrue(patch.isValid)
        patch.defaultKeyswitchNote = 24
        XCTAssertFalse(patch.isValid)
        patch.defaultKeyswitchNote = 23
        XCTAssertTrue(patch.isValid)
        patch.zones[1].articulationID = 5
        XCTAssertFalse(patch.isValid)
    }

    func testRoundRobinAndReleaseZoneMetadataAreBackwardCompatible() throws {
        let url = URL(fileURLWithPath: "/tmp/native-strings.wav")
        var attack = StudioSamplerZone(sampleURL: url, rootNote: 60)
        attack.roundRobinIndex = 1
        var release = StudioSamplerZone(sampleURL: url, rootNote: 60)
        release.roundRobinIndex = 1
        release.isReleaseTrigger = true
        let patch = StudioSamplerPatch(zones: [attack, release])
        XCTAssertTrue(patch.isValid)
        let roundTrip = try JSONDecoder().decode(
            StudioSamplerPatch.self, from: JSONEncoder().encode(patch)
        )
        XCTAssertEqual(roundTrip, patch)
        XCTAssertEqual(roundTrip.zones[1].roundRobinIndex, 1)
        XCTAssertTrue(roundTrip.zones[1].isReleaseTrigger == true)

        release.loopStartFrame = 20
        release.loopEndFrame = 100
        XCTAssertFalse(StudioSamplerPatch(zones: [attack, release]).isValid)
        release.loopStartFrame = nil
        release.loopEndFrame = nil
        release.roundRobinIndex = 8
        XCTAssertFalse(StudioSamplerPatch(zones: [attack, release]).isValid)
        release.roundRobinIndex = 1
        XCTAssertTrue(StudioSamplerPatch(zones: [attack, release]).isValid)

        let legacy = StudioSamplerPatch(sampleURL: url)
        let old = try JSONDecoder().decode(
            StudioSamplerPatch.self, from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(old.zones[0].isReleaseTrigger)
        XCTAssertNil(old.zones[0].roundRobinIndex)
    }

    func testReleaseZonePlaysThroughNativeOfflineRendering() throws {
        let attackFile = try makeSample()
        let releaseFile = try makeSample()
        defer {
            try? FileManager.default.removeItem(at: attackFile)
            try? FileManager.default.removeItem(at: releaseFile)
        }
        var attack = StudioSamplerZone(sampleURL: attackFile, rootNote: 69)
        attack.roundRobinIndex = 0
        var release = StudioSamplerZone(sampleURL: releaseFile, rootNote: 69)
        release.isReleaseTrigger = true
        release.roundRobinIndex = 0
        let sampler = try StudioSamplerInstrument(
            sampleRate: 44_100, patch: StudioSamplerPatch(zones: [attack, release])
        )
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
        XCTAssertTrue(sampler.noteOn(69, velocity: 100, channel: 0))
        XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
        XCTAssertTrue(sampler.noteOff(69, channel: 0))
        // Attack release envelope is finished; the release sample should
        // still be audible after 512 frames.
        XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
        let audio = try XCTUnwrap(buffer.floatChannelData)
        let peak = (128..<512).reduce(Float.zero) {
            max($0, abs(audio[0][$1]))
        }
        XCTAssertGreaterThan(peak, 0.001)
    }

    func testBadMappingDoesNotAttachAnInstrument() throws {
        var patch = StudioSamplerPatch(zones: [])
        XCTAssertFalse(patch.isValid)
        XCTAssertThrowsError(try StudioSamplerInstrument(sampleRate: 44_100, patch: patch))
        patch = StudioSamplerPatch(sampleURL: URL(fileURLWithPath: "/no/such/file.wav"))
        XCTAssertThrowsError(try StudioSamplerInstrument(sampleRate: 44_100, patch: patch))
    }
}
