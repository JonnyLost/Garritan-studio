import XCTest
import Foundation
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioSynthSamplerBridgeTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSynthSamplerBridge-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    func testCaptureOptionsEnforceBoundedMultisampling() {
        XCTAssertTrue(StudioSynthSamplerCapture.Options().isValid)
        XCTAssertFalse(StudioSynthSamplerCapture.Options(
            rootNotes: [], velocities: [100]).isValid)
        XCTAssertFalse(StudioSynthSamplerCapture.Options(
            rootNotes: [60, 60], velocities: [100]).isValid)
        XCTAssertFalse(StudioSynthSamplerCapture.Options(
            rootNotes: [60], velocities: [0]).isValid)
        XCTAssertFalse(StudioSynthSamplerCapture.Options(
            rootNotes: [60], velocities: [128]).isValid)
        XCTAssertFalse(StudioSynthSamplerCapture.Options(
            rootNotes: [60], velocities: [100],
            sustainSeconds: .nan).isValid)
        XCTAssertFalse(StudioSynthSamplerCapture.Options(
            rootNotes: [60], velocities: [100],
            sampleRate: 4_000).isValid)
    }

    func testSynthCaptureCreatesPortableNativeSamplerAndPreservesSource() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampleDirectory = root.appendingPathComponent("samples")
        let packageDirectory = root.appendingPathComponent("instruments")
        let original = StudioSynthPatch.individual(.analog)
        let options = StudioSynthSamplerCapture.Options(
            rootNotes: [60], velocities: [112],
            sustainSeconds: 0.12, releaseSeconds: 0.12,
            sampleRate: 44_100)
        let result = try StudioSynthSamplerCapture.capture(
            patch: original, name: "Native Analog Capture",
            options: options, sampleDirectory: sampleDirectory,
            packageDirectory: packageDirectory)
        XCTAssertEqual(result.takeCount, 1)
        XCTAssertEqual(result.packageURL.pathExtension, "studioinstrument")
        XCTAssertEqual(result.patch.zones.count, 1)
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.zones[0].rootNote, 60)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.patch.zones[0].sampleURL.path))
        XCTAssertTrue(original.validate())

        let restored = try StudioSamplerInstrumentPackage.load(
            result.packageURL,
            into: root.appendingPathComponent("reopened-samples"))
        XCTAssertEqual(restored.1.name, "Native Analog Capture")
        XCTAssertEqual(restored.0.zones.count, 1)
        XCTAssertEqual(restored.0.zones[0].rootNote, 60)
        XCTAssertTrue(restored.0.isValid)
        _ = try StudioSamplerInstrument(sampleRate: 44_100,
                                         patch: restored.0)
    }

    func testGranularCanFindSamplersWithoutModifyingTheirZones() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<512 {
            channels[0][frame] = sin(Float(frame) * 0.1) * 0.2
        }
        let audio = try AVAudioFile(
            forWriting: file,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        try audio.write(from: buffer)
        var project = Project(name: "Sampler Source")
        var track = Track(name: "My Own Instrument", type: .instrument)
        track.studioSamplerPatch = StudioSamplerPatch(sampleURL: file)
        project.tracks.append(track)
        let before = track.studioSamplerPatch
        let sources = StudioGranularSamplerBridge.sources(in: project)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].audioURL.path, file.path)
        XCTAssertTrue(sources[0].title.contains("My Own Instrument"))
        XCTAssertEqual(track.studioSamplerPatch, before)
    }
}
