import XCTest
import AVFoundation
@testable import DAWCore

final class StudioSamplerInstrumentFactoryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StudioInstrumentFactoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSample(_ url: URL, amplitude: Float = 0.2,
                             frames: Int = 8192,
                             silentStart: Int = 0,
                             silentEnd: Int = 0) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let audio = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<frames {
            audio[i] = (i >= silentStart && i < frames - silentEnd)
                ? amplitude : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }

    func testOfflinePreparationTrimsNormalizesAndPreservesSource() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raw.wav")
        let output = root.appendingPathComponent("prepared.wav")
        try writeSample(source, frames: 12_000, silentStart: 2_000,
                        silentEnd: 3_000)
        let original = try Data(contentsOf: source)
        let report = try StudioSamplerFactoryProcessor.prepare(
            source: source, destination: output,
            settings: .init(trimSilence: true, silenceThresholdDB: -50,
                            attackPaddingMilliseconds: 0,
                            normalize: true, targetPeakDB: -1,
                            fadeInMilliseconds: 0,
                            fadeOutMilliseconds: 0))
        XCTAssertEqual(report.sourceFrames, 12_000)
        XCTAssertEqual(report.outputFrames, 7_000)
        XCTAssertEqual(report.sampleRate, 44_100)
        XCTAssertEqual(report.channels, 1)
        XCTAssertEqual(report.peakBefore, 0.2, accuracy: 0.001)
        XCTAssertEqual(report.gainApplied, 4.456, accuracy: 0.02)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let prepared = try AVAudioFile(forReading: output,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: prepared.processingFormat, frameCapacity: 7_000))
        try prepared.read(into: buffer)
        let mono = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(mono[3_000], powf(10.0, -1.0 / 20.0), accuracy: 0.02)
        XCTAssertThrowsError(try StudioSamplerFactoryProcessor.prepare(
            source: source, destination: output))
    }

    func testPreparationRejectsSilenceAndInvalidSettings() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("silence.wav")
        try writeSample(source, amplitude: 0)
        let destination = root.appendingPathComponent("prepared.wav")
        XCTAssertThrowsError(try StudioSamplerFactoryProcessor.prepare(
            source: source, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try StudioSamplerFactoryProcessor.prepare(
            source: source, destination: destination,
            settings: .init(silenceThresholdDB: 30)))
    }

    func testLabeledTakeAssemblyCreatesCorrectVelocityAndMicGroups() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceA = root.appendingPathComponent("raw-a.wav")
        let sourceB = root.appendingPathComponent("raw-b.wav")
        let sourceC = root.appendingPathComponent("raw-c.wav")
        try writeSample(sourceA)
        try writeSample(sourceB)
        try writeSample(sourceC)
        let samples = root.appendingPathComponent("managed")
        let takes = [
            StudioSamplerFactoryTake(source: sourceA, rootNote: 60,
                                     velocity: 36, microphoneID: 0),
            StudioSamplerFactoryTake(source: sourceB, rootNote: 60,
                                     velocity: 116, microphoneID: 0),
            StudioSamplerFactoryTake(source: sourceC, rootNote: 60,
                                     velocity: 92, microphoneID: 2)
        ]
        let patch = try StudioSamplerInstrumentFactory.assemble(
            takes, sampleDirectory: samples)
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 3)
        XCTAssertEqual(patch.zones.filter { ($0.microphoneID ?? 0) == 0 }
            .map(\.lowestVelocity), [1, 77])
        XCTAssertEqual(patch.zones.filter { ($0.microphoneID ?? 0) == 0 }
            .map(\.highestVelocity), [76, 127])
        XCTAssertEqual(patch.zones.first?.rootNote, 60)
        XCTAssertEqual(patch.microphones?.map(\.id), [0, 2])
        XCTAssertTrue(patch.zones.allSatisfy { $0.managedFileName != nil })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: samples, includingPropertiesForKeys: nil).count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceA.path))
    }

    func testFactoryMergesArticulationsAndRejectsBadLegatoBeforeCopying() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.wav")
        try writeSample(original)
        let library = root.appendingPathComponent("managed")
        let first = try StudioSamplerInstrumentFactory.assemble([
            .init(source: original, rootNote: 60, articulation: "Legato")
        ], sampleDirectory: library)
        let merged = try StudioSamplerInstrumentFactory.assemble([
            .init(source: original, rootNote: 62, articulation: "Legato",
                  legatoFromNote: 60)
        ], extending: first, sampleDirectory: library)
        XCTAssertTrue(merged.isValid)
        XCTAssertEqual(merged.zones.count, 2)
        XCTAssertEqual(merged.zones[0].articulationID, merged.zones[1].articulationID)
        XCTAssertEqual(merged.zones[1].legatoFromNote, 60)
        XCTAssertEqual(merged.legatoEnabled, true)

        let countBefore = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil).count
        XCTAssertThrowsError(try StudioSamplerInstrumentFactory.assemble([
            .init(source: original, rootNote: 60,
                  articulation: "Legato", legatoFromNote: 60)
        ], extending: first, sampleDirectory: library))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil).count, countBefore)
    }

    func testFourOriginalStarterInstrumentsArePortableAndIdempotent() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("packages")
        let created = try StudioSamplerFactoryStarterLibrary.install(in: packages)
        XCTAssertEqual(created.count, 4)
        XCTAssertTrue(try StudioSamplerFactoryStarterLibrary.install(
            in: packages).isEmpty)
        let catalog = try StudioSamplerInstrumentPackage.listLibrary(in: packages)
        XCTAssertEqual(catalog.count, 4)
        XCTAssertTrue(catalog.allSatisfy {
            $0.metadata.tags.contains("Studio Original") && $0.zoneCount == 4
        })
        let installed = root.appendingPathComponent("samples")
        let (patch, metadata) = try StudioSamplerInstrumentPackage.load(
            try XCTUnwrap(created.first), into: installed)
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 4)
        XCTAssertTrue(metadata.tags.contains("Synthetic"))
        let sampleFile = try AVAudioFile(forReading: URL(fileURLWithPath: patch.zones[0].filePath))
        XCTAssertGreaterThan(sampleFile.length, 44_100)
    }
    func testFailedImportRecoveryPreservesPreparedCaptureOnly() throws {
        let fm = FileManager.default
        let prepared = fm.temporaryDirectory.appendingPathComponent(
            "StudioFactoryPrepared-\(UUID().uuidString).wav")
        try writeSample(prepared)
        defer { try? fm.removeItem(at: prepared) }
        let originalBytes = try Data(contentsOf: prepared)
        let take = StudioSamplerFactoryTake(source: prepared)
        let preserved = try StudioSamplerFactoryRecovery.preserve([take])
        defer { try? fm.removeItem(at: preserved) }
        let saved = preserved.appendingPathComponent(prepared.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: saved), originalBytes)
        XCTAssertEqual(try Data(contentsOf: prepared), originalBytes)

        let other = try folder()
        defer { try? fm.removeItem(at: other) }
        let external = other.appendingPathComponent("user.wav")
        try writeSample(external)
        XCTAssertThrowsError(try StudioSamplerFactoryRecovery.preserve([
            StudioSamplerFactoryTake(source: external)
        ]))
        XCTAssertTrue(fm.fileExists(atPath: external.path))
    }

}
