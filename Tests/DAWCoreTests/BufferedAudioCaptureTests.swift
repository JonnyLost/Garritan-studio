import XCTest
import AVFoundation
@testable import DAWCore

final class BufferedAudioCaptureTests: XCTestCase {
    func testQueuedCaptureFlushes24BitStereoWAVWithoutAudioHardware() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BufferedCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.wav")

        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        var capture: BufferedAudioCapture? = try BufferedAudioCapture(
            file: file, sampleRate: 44_100
        )
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        input.frameLength = 256
        let channels = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<256 {
            channels[0][frame] = 0.25
            channels[1][frame] = -0.125
        }

        capture?.append(input)
        let result = try XCTUnwrap(capture?.finish())
        XCTAssertTrue(result.succeeded, result.writeError ?? "Dropped \(result.droppedFrames) frames")
        XCTAssertEqual(result.writtenFrames, 256)
        XCTAssertEqual(result.droppedFrames, 0)
        capture = nil

        let reader = try AVAudioFile(forReading: output)
        XCTAssertEqual(reader.length, 256)
        let decoded = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 256)
        )
        try reader.read(into: decoded)
        let decodedChannels = try XCTUnwrap(decoded.floatChannelData)
        XCTAssertEqual(decodedChannels[0][0], 0.25, accuracy: 0.001)
        XCTAssertEqual(decodedChannels[1][255], -0.125, accuracy: 0.001)
    }
}
