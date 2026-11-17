import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerSFZImporterTests: XCTestCase {
    private func u16(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value),
              UInt8(truncatingIfNeeded: value >> 8)])
    }
    private func u32(_ value: UInt32) -> Data {
        u16(UInt16(truncatingIfNeeded: value)) +
        u16(UInt16(truncatingIfNeeded: value >> 16))
    }

    @discardableResult
    private func wav(at url: URL) throws -> Data {
        let frames = 128
        var data = Data("RIFF".utf8)
        data.append(u32(UInt32(36 + frames * 2)))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        data.append(u32(16))
        data.append(u16(1))
        data.append(u16(1))
        data.append(u32(44_100))
        data.append(u32(88_200))
        data.append(u16(2))
        data.append(u16(16))
        data.append(contentsOf: Data("data".utf8))
        data.append(u32(UInt32(frames * 2)))
        for frame in 0..<frames {
            data.append(u16(UInt16(truncatingIfNeeded: frame * 12)))
        }
        try data.write(to: url)
        return data
    }

    func testSFZInheritanceAndNonDestructivePreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Samples"),
                                                withIntermediateDirectories: true)
        let sample = root.appendingPathComponent("Samples/tone.wav")
        let originalAudio = try wav(at: sample)
        let sfz = root.appendingPathComponent("test.sfz")
        try """
        <control> default_path=Samples/
        <global> lovel=12 hivel=99
        <group> lokey=48 hikey=72
        <region> sample=tone.wav pitch_keycenter=60 loop_mode=no_loop
        """.write(to: sfz, atomically: true, encoding: .utf8)
        let result = try StudioSamplerSFZImporter.preview(sfz)
        XCTAssertEqual(result.patch.zones.count, 1)
        let zone = try XCTUnwrap(result.patch.zones.first)
        XCTAssertEqual(zone.rootNote, 60)
        XCTAssertEqual(zone.lowestNote, 48)
        XCTAssertEqual(zone.highestNote, 72)
        XCTAssertEqual(zone.lowestVelocity, 12)
        XCTAssertEqual(zone.highestVelocity, 99)
        XCTAssertEqual(try Data(contentsOf: sample), originalAudio)
    }

    func testRepeatedSFZRegionsImportOneManagedSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-dedupe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("tone.wav")
        let original = try wav(at: source)
        let sfz = root.appendingPathComponent("dedupe.sfz")
        try """
        <region> sample=tone.wav lokey=48 hikey=60
        <region> sample=tone.wav lokey=61 hikey=72
        """.write(to: sfz, atomically: true, encoding: .utf8)
        let managed = root.appendingPathComponent("managed")
        let result = try StudioSamplerSFZImporter.importInstrument(sfz, into: managed)
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.zones.count, 2)
        XCTAssertEqual(result.patch.zones.map(\.lowestNote), [48, 61])
        XCTAssertEqual(Set(result.patch.zones.map(\.filePath)).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: managed, includingPropertiesForKeys: nil).count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        // A multi-zone external instrument must remain portable once saved
        // as Studio's native package, without copying the source twice.
        let package = root.appendingPathComponent("RoundTrip.studioinstrument")
        try StudioSamplerInstrumentPackage.export(
            result.patch,
            metadata: StudioSamplerInstrumentPackage.Metadata(name: "Imported SFZ"),
            to: package)
        let (reloaded, _) = try StudioSamplerInstrumentPackage.load(
            package, into: root.appendingPathComponent("reloaded"))
        XCTAssertTrue(reloaded.isValid)
        XCTAssertEqual(reloaded.zones.map(\.lowestNote), [48, 61])
        XCTAssertEqual(Set(reloaded.zones.map(\.filePath)).count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(
            fileURLWithPath: reloaded.zones[0].filePath)), original)
    }

    func testExplicitSFZSamplesRootResolvesMissingRecordingWithoutTraversal() throws {
        let instrumentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-exs-instrument-\(UUID().uuidString)")
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-exs-samples-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: instrumentRoot)
            try? FileManager.default.removeItem(at: audioRoot)
        }
        try FileManager.default.createDirectory(
            at: instrumentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: audioRoot.appendingPathComponent("Samples"),
            withIntermediateDirectories: true)
        let sample = audioRoot.appendingPathComponent("Samples/tone.wav")
        try wav(at: sample)
        let sfz = instrumentRoot.appendingPathComponent("external.sfz")
        try "<region> sample=Samples/tone.wav".write(
            to: sfz, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try StudioSamplerSFZImporter.preview(sfz))
        let preview = try StudioSamplerSFZImporter.preview(
            sfz, samplesRoot: audioRoot)
        XCTAssertEqual(preview.patch.zones[0].sampleURL, sample)
        let managed = instrumentRoot.appendingPathComponent("managed")
        let imported = try StudioSamplerSFZImporter.importInstrument(
            sfz, into: managed, samplesRoot: audioRoot)
        XCTAssertEqual(imported.patch.zones.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: managed, includingPropertiesForKeys: nil).count, 1)
    }

    func testSFZSymlinkOutsideAuthorizedRootIsNotImported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-symlink-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside,
                                                 withIntermediateDirectories: true)
        let sample = outside.appendingPathComponent("sample.wav")
        try Data([1, 2, 3, 4]).write(to: sample)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sample.wav"),
            withDestinationURL: sample)
        let sfz = root.appendingPathComponent("unsafe-link.sfz")
        try "<region> sample=sample.wav".write(
            to: sfz, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try StudioSamplerSFZImporter.preview(sfz))
    }

    func testSFZRejectsCorruptAudioBeforeCopying() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-bad-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("bad.wav"))
        let sfz = root.appendingPathComponent("bad.sfz")
        try "<region> sample=bad.wav".write(to: sfz,
                                              atomically: true, encoding: .utf8)
        let managed = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerSFZImporter.importInstrument(
            sfz, into: managed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
    }

    func testSFZLoopMustFitInsideActualRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-invalid-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try wav(at: root.appendingPathComponent("tone.wav"))
        let sfz = root.appendingPathComponent("test.sfz")
        try "<region> sample=tone.wav loop_mode=loop_sustain loop_start=4 loop_end=999"
            .write(to: sfz, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try StudioSamplerSFZImporter.preview(sfz))
        try "<region> sample=tone.wav loop_mode=loop_sustain loop_start=4 loop_end=50"
            .write(to: sfz, atomically: true, encoding: .utf8)
        let valid = try StudioSamplerSFZImporter.preview(sfz)
        XCTAssertEqual(valid.patch.zones[0].loopStartFrame, 4)
        XCTAssertEqual(valid.patch.zones[0].loopEndFrame, 51)
    }

    func testRejectsParentTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sfz = root.appendingPathComponent("unsafe.sfz")
        try "<region> sample=../outside.wav".write(to: sfz, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try StudioSamplerSFZImporter.preview(sfz))
    }

    func testRejectsMissingSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sfz = root.appendingPathComponent("missing.sfz")
        try "<region> sample=missing.wav".write(to: sfz, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try StudioSamplerSFZImporter.preview(sfz))
    }
}
