import XCTest
import AVFoundation
@testable import DAWCore

/// Tests real PCM extraction and the existing native release-trigger mapping.
/// No installed Audio Unit or licensed sample library is required.
final class StudioAutoSamplerReleaseCaptureTests: XCTestCase {
    private let sampleRate = 44_100.0

    private func makeCapturedWAV(heldFrames: Int, tailFrames: Int,
                                 tailIsAudible: Bool) throws
        -> (folder: URL, url: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-release-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("capture.wav")
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: 512))
        let total = heldFrames + tailFrames
        var cursor = 0
        while cursor < total {
            let count = min(512, total - cursor)
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<count {
                let frame = cursor + i
                // A constant amplitude is deliberately used in the release
                // test to verify the EXACT note-off frame is the new start.
                let value: Float = frame < heldFrames ? 0.11
                    : (tailIsAudible ? 0.31 : 0.0)
                channels[0][i] = value
                channels[1][i] = value * 0.5
            }
            try file.write(from: buffer)
            cursor += count
        }
        return (folder, url)
    }

    func testNoteOffRecordingBecomesSeparateMappedReleaseZone() throws {
        let held = 22_050 // 0.5 second; note-off occurred at this frame
        let source = try makeCapturedWAV(heldFrames: held,
                                         tailFrames: 11_025,
                                         tailIsAudible: true)
        defer { try? FileManager.default.removeItem(at: source.folder) }
        let originalBytes = try Data(contentsOf: source.url)
        let take = StudioSamplerFactoryTake(source: source.url,
                                             rootNote: 60, velocity: 90)
        let result = try StudioAutoSamplerReleaseCapture.extract(
            from: [take], sustainSeconds: 0.5,
            sampleRate: sampleRate, into: source.folder)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.skippedCount, 0)
        let released = try XCTUnwrap(result.takes.first)
        XCTAssertTrue(released.releaseTrigger)
        XCTAssertEqual(released.rootNote, take.rootNote)
        XCTAssertEqual(released.velocity, take.velocity)
        XCTAssertEqual(try Data(contentsOf: source.url), originalBytes)

        let releaseFile = try AVAudioFile(
            forReading: released.source,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(releaseFile.length, AVAudioFramePosition(11_025))
        let frameBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: releaseFile.processingFormat, frameCapacity: 16))
        try releaseFile.read(into: frameBuffer, frameCount: 16)
        let channels = try XCTUnwrap(frameBuffer.floatChannelData)
        XCTAssertEqual(channels[0][0], 0.31, accuracy: 0.0001)
        XCTAssertEqual(channels[1][0], 0.155, accuracy: 0.0001)

        let sampleDir = source.folder.appendingPathComponent("Managed")
        let packageDir = source.folder.appendingPathComponent("Instruments")
        var patch = try StudioSamplerInstrumentFactory.assemble(
            [take, released], sampleDirectory: sampleDir)
        // With isolated test directories, keep explicit absolute paths.
        for index in patch.zones.indices {
            patch.zones[index].managedFileName = nil
        }
        XCTAssertTrue(patch.isValid)
        patch = StudioAutoSamplerReleaseCapture.smoothingReleaseEndings(in: patch)
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 2)
        XCTAssertEqual(
            patch.zones.first(where: { $0.isReleaseTrigger == true })?.fadeOutFrames,
            256)
        XCTAssertEqual(
            patch.zones.first(where: { $0.isReleaseTrigger != true })?.fadeOutFrames,
            nil)
        XCTAssertEqual(patch.zones.filter { $0.isReleaseTrigger == true }.count, 1)
        XCTAssertEqual(patch.zones.filter { $0.isReleaseTrigger != true }.count, 1)
        XCTAssertTrue(patch.zones.allSatisfy { !$0.hasSustainLoop })
        let package = try StudioSamplerInstrumentPackage.saveToLibrary(
            patch, metadata: .init(name: "Release Sample Test"),
            in: packageDir)
        let imported = try StudioSamplerInstrumentPackage.load(
            package, into: source.folder.appendingPathComponent("Reopened"))
        XCTAssertTrue(imported.0.isValid)
        XCTAssertEqual(imported.0.zones.count, 2)
        XCTAssertEqual(imported.0.zones.filter { $0.isReleaseTrigger == true }.count, 1)
    }

    func testSilentNoteOffDoesNotGenerateReleaseZone() throws {
        let source = try makeCapturedWAV(heldFrames: 22_050,
                                         tailFrames: 11_025,
                                         tailIsAudible: false)
        defer { try? FileManager.default.removeItem(at: source.folder) }
        let take = StudioSamplerFactoryTake(source: source.url,
                                             rootNote: 48, velocity: 64)
        let result = try StudioAutoSamplerReleaseCapture.extract(
            from: [take], sustainSeconds: 0.5, sampleRate: sampleRate,
            into: source.folder)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: source.folder, includingPropertiesForKeys: nil).count, 1)
    }

    func testReleaseSampleZoneBudget() {
        XCTAssertTrue(StudioAutoSamplerReleaseCapture.fitsZoneLimit(
            heldSampleCount: 64, includeReleases: true))
        XCTAssertFalse(StudioAutoSamplerReleaseCapture.fitsZoneLimit(
            heldSampleCount: 65, includeReleases: true))
        XCTAssertTrue(StudioAutoSamplerReleaseCapture.fitsZoneLimit(
            heldSampleCount: 65, includeReleases: false))
        XCTAssertFalse(StudioAutoSamplerReleaseCapture.fitsZoneLimit(
            heldSampleCount: 129, includeReleases: false))
        XCTAssertFalse(StudioAutoSamplerReleaseCapture.fitsZoneLimit(
            heldSampleCount: 0, includeReleases: true))
    }
}
