import Foundation
import AVFoundation
import AudioToolbox
import XCTest
@testable import DAWCore

/// End-to-end worker decode and PCM page handoff, without a hardware device.
final class StudioCoreAudioClipStreamingTests: XCTestCase {
    private func makeWave(_ url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 8192
        ))
        pcm.frameLength = 8192
        let channels = try XCTUnwrap(pcm.floatChannelData)
        for index in 0..<8192 {
            channels[0][index] = Float(index % 1000) / 1000.0
            channels[1][index] = -channels[0][index]
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
    }

    func testPrefilledAudioPagePlaysWithoutRenderThreadDiskRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioStream-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.wav")
        try makeWave(source)

        let renderer = AudioClipRenderer(sampleRate: 48_000)
        try renderer.scheduleClip(
            url: source, trackID: TrackID(),
            startSample: 1024, offsetSample: 512, endSample: 1024 + 8192,
            volume: 0.5
        )
        renderer.preparePlayback(at: 1024)

        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2
        ))
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 512
        ))
        output.frameLength = 512
        let channels = try XCTUnwrap(output.floatChannelData)
        for index in 0..<512 {
            channels[0][index] = 0
            channels[1][index] = 0
        }

        renderer.render(
            into: output.mutableAudioBufferList,
            currentSample: 1024, frameCount: 512
        )

        XCTAssertEqual(channels[0][0], 0.256, accuracy: 0.0001)
        XCTAssertEqual(channels[1][0], -0.256, accuracy: 0.0001)
        XCTAssertEqual(channels[0][100], 0.306, accuracy: 0.0001)
        XCTAssertEqual(renderer.totalUnderrunFrames, 0)
        renderer.pauseStreaming()
    }

    func testSeekPrefillAndOfflineDecodeRemainIndependent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioStreamSeek-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.wav")
        try makeWave(source)

        let renderer = AudioClipRenderer(sampleRate: 48_000)
        try renderer.scheduleClip(
            url: source, trackID: TrackID(),
            startSample: 0, offsetSample: 0, endSample: 8192,
            volume: 1
        )
        renderer.preparePlayback(at: 4096)

        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2
        ))
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 128
        ))
        output.frameLength = 128
        let channels = try XCTUnwrap(output.floatChannelData)
        channels[0].initialize(repeating: 0, count: 128)
        channels[1].initialize(repeating: 0, count: 128)
        renderer.render(
            into: output.mutableAudioBufferList,
            currentSample: 4096, frameCount: 128
        )
        XCTAssertEqual(channels[0][0], 0.096, accuracy: 0.0001)
        XCTAssertEqual(renderer.totalUnderrunFrames, 0)

        renderer.pauseStreaming()
        channels[0].initialize(repeating: 0, count: 128)
        channels[1].initialize(repeating: 0, count: 128)
        renderer.renderOffline(
            into: output.mutableAudioBufferList,
            currentSample: 0, frameCount: 128
        )
        XCTAssertEqual(channels[0][100], 0.1, accuracy: 0.0001)
        XCTAssertEqual(channels[1][100], -0.1, accuracy: 0.0001)
    }
}
