import XCTest
import Foundation
import AVFoundation
@testable import DAWCore

/// Deterministic synthetic WAV tests: no licensed Audio Unit is needed.
final class StudioAutoSamplerLoopingTests: XCTestCase {
    private let rate = 44_100.0

    private func makeRecording(
        frames: Int,
        sample: (Int) -> Float
    ) throws -> (folder: URL, url: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-auto-loop-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("take.wav")
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: rate, channels: 1) else {
            throw NSError(domain: "AutoLoopTests", code: 1)
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)
        else { throw NSError(domain: "AutoLoopTests", code: 2) }
        var cursor = 0
        while cursor < frames {
            let count = min(2048, frames - cursor)
            buffer.frameLength = AVAudioFrameCount(count)
            guard let channel = buffer.floatChannelData?[0] else {
                throw NSError(domain: "AutoLoopTests", code: 3)
            }
            for i in 0..<count { channel[i] = sample(cursor + i) }
            try writer.write(from: buffer)
            cursor += count
        }
        return (folder, url)
    }

    func testSteadyToneGetsNonDestructiveEditableCrossfadeLoop() throws {
        let held = 57_330  // 1.3 seconds
        let source = try makeRecording(frames: held + 22_050) { frame in
            0.25 * sin(Float(frame) * 2 * Float.pi * 220 / 44_100)
        }
        defer { try? FileManager.default.removeItem(at: source.folder) }
        let before = try Data(contentsOf: source.url)
        let take = StudioSamplerFactoryTake(
            source: source.url, rootNote: 60, velocity: 96)
        let analysis = try StudioAutoSamplerLooping.analyze(
            takes: [take], sustainSeconds: 1.3, sampleRate: rate)
        XCTAssertEqual(analysis.attempted, 1)
        XCTAssertEqual(analysis.suggested, 1)
        let original = StudioSamplerPatch(
            zones: [StudioSamplerZone(sampleURL: source.url, rootNote: 60)])
        let processed = StudioAutoSamplerLooping.apply(
            analysis, to: original, takes: [take])
        XCTAssertEqual(processed.loopCount, 1)
        XCTAssertTrue(processed.patch.isValid)
        XCTAssertFalse(original.zones[0].hasSustainLoop)
        let zone = try XCTUnwrap(processed.patch.zones.first)
        XCTAssertTrue(zone.hasSustainLoop)
        XCTAssertGreaterThan(zone.loopCrossfadeFrames ?? 0, 0)
        XCTAssertLessThanOrEqual(zone.loopEndFrame ?? 0, UInt32(held * 90 / 100))

        // Loop markers survive patch serialization; the captured source audio
        // remains bit-for-bit identical and can be edited manually later.
        let roundtrip = try JSONDecoder().decode(
            StudioSamplerPatch.self,
            from: JSONEncoder().encode(processed.patch))
        XCTAssertEqual(roundtrip, processed.patch)
        XCTAssertEqual(try Data(contentsOf: source.url), before)
    }

    func testShortAndDecayingTakesRemainOneShots() throws {
        let short = try makeRecording(frames: 30_870) { frame in
            0.2 * sin(Float(frame) * 0.07)
        }
        defer { try? FileManager.default.removeItem(at: short.folder) }
        let shortTake = StudioSamplerFactoryTake(
            source: short.url, rootNote: 60, velocity: 96)
        let shortResult = try StudioAutoSamplerLooping.analyze(
            takes: [shortTake], sustainSeconds: 0.6, sampleRate: rate)
        XCTAssertEqual(shortResult.suggested, 0)
        XCTAssertEqual(shortResult.skipped, 1)

        let decaying = try makeRecording(frames: 66_150) { frame in
            let elapsed = Double(frame) / 44_100.0
            let gain = Float(exp(-8 * elapsed))
            return gain * 0.4 * sin(Float(frame) * 0.11)
        }
        defer { try? FileManager.default.removeItem(at: decaying.folder) }
        let transient = StudioSamplerFactoryTake(
            source: decaying.url, rootNote: 48, velocity: 112)
        let result = try StudioAutoSamplerLooping.analyze(
            takes: [transient], sustainSeconds: 1.0, sampleRate: rate)
        XCTAssertEqual(result.suggested, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    func testSuggestionsRespectVelocityPartitionsAndIgnoreReleaseZones() {
        let url = URL(fileURLWithPath: "/tmp/auto-loop-mapping.wav")
        let low = StudioSamplerZone(
            sampleURL: url, rootNote: 60, lowestVelocity: 1, highestVelocity: 70)
        let high = StudioSamplerZone(
            sampleURL: url, rootNote: 60, lowestVelocity: 71, highestVelocity: 127)
        var release = StudioSamplerZone(
            sampleURL: url, rootNote: 60, lowestVelocity: 1, highestVelocity: 127)
        release.isReleaseTrigger = true
        let patch = StudioSamplerPatch(zones: [low, high, release])
        let takeLow = StudioSamplerFactoryTake(
            source: url, rootNote: 60, velocity: 50)
        let takeHigh = StudioSamplerFactoryTake(
            source: url, rootNote: 60, velocity: 110)
        let suggestion = StudioSamplerLoopSuggestion(
            startFrame: 15_000, endFrame: 30_000,
            crossfadeFrames: 256, mismatchScore: 0.002)
        let analysis = StudioAutoSamplerLooping.Analysis(
            attempted: 2, recommendations: [
                .init(note: 60, velocity: 50): suggestion,
                .init(note: 60, velocity: 110): suggestion
            ])
        let applied = StudioAutoSamplerLooping.apply(
            analysis, to: patch, takes: [takeLow, takeHigh])
        XCTAssertEqual(applied.loopCount, 2)
        XCTAssertTrue(applied.patch.zones[0].hasSustainLoop)
        XCTAssertTrue(applied.patch.zones[1].hasSustainLoop)
        XCTAssertFalse(applied.patch.zones[2].hasSustainLoop)
        XCTAssertEqual(applied.patch.zones[0].loopCrossfadeFrames, 256)
        XCTAssertTrue(applied.patch.isValid)
        XCTAssertEqual(patch.zones[0].loopStartFrame, nil)
    }
}
