import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import DAWCore

/// A self-contained movie generated on the CI Mac. This checks AVFoundation's
/// actual H.264 import, duration, frame-rate metadata and frame decoding,
/// not merely the Swift SMPTE arithmetic. No external media is required.
final class StudioPictureMediaAcceptanceTests: XCTestCase {
    func testNativeVideoImportDecodesFramesAndMatchesSMPTEPositions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-picture-ci-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "")
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<12 {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer)
            XCTAssertEqual(status, kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ptr = CVPixelBufferGetBaseAddress(buffer) {
                memset(ptr, Int32(35 + frame * 4),
                       CVPixelBufferGetBytesPerRow(buffer) * 64)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            // The encoder drains in the background, even in CI.
            for _ in 0..<100 where !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertTrue(input.isReadyForMoreMediaData,
                          "H.264 encoder did not accept a generated frame")
            guard input.isReadyForMoreMediaData else { return }
            XCTAssertTrue(adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24)),
                writer.error?.localizedDescription ?? "Video append failed")
        }

        input.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.finishWriting { done.resume() }
        }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let asset = AVURLAsset(url: url)
        XCTAssertTrue(try await asset.load(.isPlayable))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(fps, 24, accuracy: 0.1)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(seconds, 0.4)

        let image = AVAssetImageGenerator(asset: asset)
        image.appliesPreferredTrackTransform = true
        let decoded = try await image.image(at: CMTime(value: 7, timescale: 24)).image
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 64)

        let picture = StudioPictureProject(url: url, durationSeconds: seconds,
                                            frameRate: .fps24)
        let frame = picture.movieFrame(atProjectSeconds: 7.0 / 24)
        XCTAssertEqual(frame, 7)
        XCTAssertEqual(picture.timecode(atMovieFrame: frame), "01:00:00:07")
    }
}
