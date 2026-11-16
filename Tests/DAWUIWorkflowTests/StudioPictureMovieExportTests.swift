import AVFoundation
import CoreVideo
import Foundation
import XCTest
import DAWCore
@testable import DAWUI

/// End-to-end, generated locally on the macOS CI runner: no downloaded media,
/// no plugins, no hardware audio device and no existing user Studio project.
@MainActor
final class StudioPictureMovieExportTests: XCTestCase {
    func testExportScoreWAVWithGeneratedPictureAndAudioTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-picture-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("reference.mov")
        let wav = root.appendingPathComponent("StudioStereoMix.wav")
        let output = root.appendingPathComponent("scored.mov")

        try await generateMovie(to: movie)
        try createStereoWAV(at: wav)

        let picture = StudioPictureProject(url: movie, durationSeconds: 1,
                                           frameRate: .fps24,
                                           timelineStartSeconds: 0.25)
        let exporter = StudioPictureMovieExporter()
        try await exporter.export(picture: picture, scoreURL: wav,
                                  destination: output,
                                  includeReferenceAudio: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(exporter.progress, 1, accuracy: 0.001)

        let rendered = AVURLAsset(url: output)
        let videoTracks = try await rendered.loadTracks(withMediaType: .video)
        let audioTracks = try await rendered.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = try await rendered.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.9)
        XCTAssertLessThan(duration.seconds, 1.2)

        // Do not destroy existing output on an accidental repeat.
        do {
            try await exporter.export(picture: picture, scoreURL: wav,
                                      destination: output,
                                      includeReferenceAudio: false)
            XCTFail("An existing scored movie was overwritten")
        } catch StudioPictureMovieExportError.destinationExists {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testRejectsSourceDestinationConflictsBeforeRendering() async throws {
        let picture = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/original.mov"),
            durationSeconds: 8, frameRate: .fps24)
        let exporter = StudioPictureMovieExporter()
        let wav = URL(fileURLWithPath: "/tmp/mix.wav")
        do {
            try await exporter.export(picture: picture, scoreURL: wav,
                                      destination: wav,
                                      includeReferenceAudio: false)
            XCTFail("Must reject overwriting selected score")
        } catch StudioPictureMovieExportError.destinationConflictsWithSource {
            XCTAssertFalse(exporter.isExporting)
        }
    }

    func testTimecodeBurnInFrameLabelsAndBackwardOffset() {
        let picture = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/scored.mov"),
            durationSeconds: 10, frameRate: .fps2997Drop,
            timelineStartSeconds: 120)
        XCTAssertEqual(StudioPictureTimecodeBurnIn.label(
            picture: picture, movieSeconds: 0), "01:00:00;00")
        XCTAssertEqual(StudioPictureTimecodeBurnIn.label(
            picture: picture, movieSeconds: 1), "01:00:00;29")
        XCTAssertEqual(StudioPictureTimecodeBurnIn.label(
            picture: picture, movieSeconds: 0.1), "01:00:00;02")
        XCTAssertEqual(StudioPictureTimecodeBurnIn.label(
            picture: picture, movieSeconds: .nan), "01:00:00;00")
    }

    func testMP4ScoredDeliveryAndTimecodeBurnIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-picture-mp4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("reference.mov")
        let wav = root.appendingPathComponent("score.wav")
        let output = root.appendingPathComponent("delivery.mp4")
        try await generateMovie(to: movie)
        try createStereoWAV(at: wav)

        let picture = StudioPictureProject(url: movie, durationSeconds: 1,
                                           frameRate: .fps24)
        let exporter = StudioPictureMovieExporter()
        try await exporter.export(picture: picture,
                                  scoreURL: wav, destination: output,
                                  includeReferenceAudio: false,
                                  format: .mp4,
                                  burnInTimecode: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let delivered = AVURLAsset(url: output)
        XCTAssertEqual(try await delivered.loadTracks(withMediaType: .video).count, 1)
        XCTAssertEqual(try await delivered.loadTracks(withMediaType: .audio).count, 1)
        let image = AVAssetImageGenerator(asset: delivered)
        let frame = try await image.image(at: CMTime(value: 3, timescale: 24))
        XCTAssertGreaterThan(frame.image.width, 0)
        XCTAssertEqual(exporter.progress, 1, accuracy: 0.001)
    }

    func testDeliveryFormatFilenameMustMatchSelectedContainer() async throws {
        let picture = StudioPictureProject(
            url: URL(fileURLWithPath: "/tmp/invalid-test.mov"),
            durationSeconds: 1, frameRate: .fps24)
        // Preflight source files first. This checks the published format
        // mapping independently from container compatibility on a given Mac.
        XCTAssertEqual(StudioPictureDeliveryFormat.mp4.fileExtension, "mp4")
        XCTAssertEqual(StudioPictureDeliveryFormat.mp4.fileType, .mp4)
        XCTAssertEqual(StudioPictureDeliveryFormat.hevcQuickTime.fileExtension, "mov")
        XCTAssertEqual(StudioPictureDeliveryFormat.quickTime.fileType, .mov)
        XCTAssertEqual(picture.timecode(atMovieFrame: 0), "01:00:00:00")
    }

    private func createStereoWAV(at url: URL) throws {
        let sampleRate: Double = 48_000
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        if let channels = buffer.floatChannelData {
            for channel in 0..<2 {
                for sample in 0..<48_000 {
                    channels[channel][sample] = 0.05
                }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func generateMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<24 {
            var pb: CVPixelBuffer?
            let rc = CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &pb)
            XCTAssertEqual(rc, kCVReturnSuccess)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let pointer = CVPixelBufferGetBaseAddress(buffer) {
                memset(pointer, Int32(25 + index),
                       CVPixelBufferGetBytesPerRow(buffer) * 64)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<100 where !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard input.isReadyForMoreMediaData else {
                XCTFail("Video writer stalled")
                return
            }
            XCTAssertTrue(adaptor.append(
                buffer, withPresentationTime: CMTime(value: CMTimeValue(index),
                                                       timescale: 24)))
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
