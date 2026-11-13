import XCTest
import Foundation
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioSharedSampleCacheTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSharedPCM-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeWAV(_ destination: URL, frames: Int = 2048,
                          frequency: Float = 0.11) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format,
                             frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<frames {
            let value = sin(Float(frame) * frequency) * 0.25
            channels[0][frame] = value
            channels[1][frame] = value * 0.5
        }
        let writer = try AVAudioFile(
            forWriting: destination, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }

    func testIdenticalFileReturnsIdenticalNativeAllocation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = folder.appendingPathComponent("stereo.wav")
        try writeWAV(sample)
        let cache = StudioSharedSampleCache(maxBytes: 64 * 1024)
        let first = try XCTUnwrap(cache.acquire(url: sample, maxFrames: 4096))
        let second = try XCTUnwrap(cache.acquire(url: sample, maxFrames: 524288))
        XCTAssertEqual(first.handle, second.handle)
        XCTAssertEqual(first.frames, 2048)
        XCTAssertEqual(first.sampleRate, 44_100)
        let stats = cache.statistics()
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.entries, 1)
        XCTAssertEqual(stats.residentBytes, 2048 * 3 * MemoryLayout<Float>.size)
    }

    func testChangedFileRevisionInvalidatesOldAllocation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = folder.appendingPathComponent("mutable.wav")
        try writeWAV(sample)
        let cache = StudioSharedSampleCache()
        let original = try XCTUnwrap(cache.acquire(url: sample, maxFrames: 3000))
        try FileManager.default.removeItem(at: sample)
        try writeWAV(sample, frames: 3072, frequency: 0.08)
        let changed = try XCTUnwrap(cache.acquire(url: sample, maxFrames: 3000))
        XCTAssertNotEqual(original.handle, changed.handle)
        XCTAssertEqual(changed.frames, 3000)
        XCTAssertEqual(cache.statistics().misses, 2)
        XCTAssertEqual(original.frames, 2048)
    }

    func testLRUEvictionCannotInvalidateAStillOwnedPCMHandle() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("one.wav")
        let b = folder.appendingPathComponent("two.wav")
        try writeWAV(a)
        try writeWAV(b, frequency: 0.07)
        let cache = StudioSharedSampleCache(maxBytes: 30000)
        let pinned = try XCTUnwrap(cache.acquire(url: a, maxFrames: 2048))
        _ = try XCTUnwrap(cache.acquire(url: b, maxFrames: 2048))
        XCTAssertEqual(cache.statistics().entries, 1)
        XCTAssertLessThanOrEqual(cache.statistics().residentBytes, 30000)
        let reloaded = try XCTUnwrap(cache.acquire(url: a, maxFrames: 2048))
        XCTAssertNotEqual(pinned.handle, reloaded.handle)
        XCTAssertEqual(pinned.frames, 2048)
        cache.purge()
        XCTAssertEqual(cache.statistics().entries, 0)
        XCTAssertEqual(pinned.frames, 2048)
    }

    func testSamplerAndGranularLoadSharedPCMAndKeepPlayingAfterEviction() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = folder.appendingPathComponent("shared.wav")
        try writeWAV(sample, frames: 8192)
        let source = StudioSamplerPatch(sampleURL: sample)
        let sampler = try StudioSamplerInstrument(
            sampleRate: 44_100, patch: source)
        var granularPatch = StudioGranularPatch()
        granularPatch.importedAudioPath = sample.path
        let granular = try StudioGranularInstrument(
            sampleRate: 44_100, patch: granularPatch)
        XCTAssertTrue(granular.isUsingSharedPCM)
        let cached = try XCTUnwrap(StudioSharedSampleCache.shared.acquire(
            url: sample, maxFrames: 524288))
        XCTAssertEqual(cached.frames, 8192)
        StudioSharedSampleCache.shared.purge()

        // The native engines have separate retained owners. Cache eviction
        // must not interrupt active notes or free a renderer's PCM pointer.
        XCTAssertTrue(sampler.noteOn(60, velocity: 110, channel: 0))
        let engine = AVAudioEngine()
        engine.attach(granular.audioNode)
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 2))
        engine.connect(granular.audioNode, to: engine.mainMixerNode,
                       format: format)
        try engine.enableManualRenderingMode(.offline,
                                             format: format,
                                             maximumFrameCount: 512)
        try engine.start()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }
        XCTAssertTrue(granular.noteOn(60, velocity: 110))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 512))
        var peak: Float = 0
        for _ in 0..<20 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for index in 0..<Int(buffer.frameLength) {
                XCTAssertTrue(samples[0][index].isFinite)
                XCTAssertTrue(samples[1][index].isFinite)
                peak = max(peak, abs(samples[0][index]))
            }
        }
        XCTAssertGreaterThan(peak, 0.001)
        XCTAssertTrue(sampler.allNotesOff())
        XCTAssertTrue(granular.allNotesOff())
    }
}
