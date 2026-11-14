import XCTest
import AVFoundation
@testable import DAWUI
import DAWCore

/// Tests the actual PCM output stage, independently of device playback.
/// This runs on the macOS CI runner without ARIA or an audio interface.
final class StudioExportPCMWriterTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-export-tests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    private func stereoFixture(at url: URL, frames: Int = 400) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 2
        )!
        let pcm = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        )!
        pcm.frameLength = AVAudioFrameCount(frames)
        guard let channels = pcm.floatChannelData else {
            XCTFail("Missing fixture channels")
            return
        }
        for index in 0..<frames {
            channels[0][index] = 0.8
            channels[1][index] = 0.2
        }
        try file.write(from: pcm)
    }

    func testMonoDownmixWritesActualSingleChannelWAVAndPadsTail() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("stereo.wav")
        let output = folder.appendingPathComponent("mono.wav")
        try stereoFixture(at: source)

        try StudioExportPCMWriter.convert(
            source: source, destination: output, channels: 1,
            bitDepth: 24, targetFrames: 512
        )

        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.processingFormat.channelCount, 1)
        XCTAssertEqual(result.fileFormat.channelCount, 1)
        XCTAssertEqual(result.length, 512)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: result.processingFormat, frameCapacity: 512
        )!
        try result.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.5, accuracy: 0.002)
        XCTAssertEqual(buffer.floatChannelData![0][399], 0.5, accuracy: 0.002)
        XCTAssertEqual(buffer.floatChannelData![0][400], 0, accuracy: 0.002)
        XCTAssertEqual(buffer.floatChannelData![0][511], 0, accuracy: 0.002)
    }

    func testStereoPCMOutputPreservesBothChannels() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        let output = folder.appendingPathComponent("export.wav")
        try stereoFixture(at: source)

        try StudioExportPCMWriter.convert(
            source: source, destination: output, channels: 2,
            bitDepth: 16, targetFrames: 400
        )

        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.fileFormat.channelCount, 2)
        XCTAssertEqual(result.length, 400)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: result.processingFormat, frameCapacity: 400
        )!
        try result.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.8, accuracy: 0.003)
        XCTAssertEqual(buffer.floatChannelData![1][0], 0.2, accuracy: 0.003)
    }
}
