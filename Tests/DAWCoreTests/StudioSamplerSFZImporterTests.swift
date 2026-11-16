import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerSFZImporterTests: XCTestCase {
    func testSFZInheritanceAndNonDestructivePreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Samples"),
                                                withIntermediateDirectories: true)
        let sample = root.appendingPathComponent("Samples/tone.wav")
        try Data([1, 2, 3, 4]).write(to: sample)
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
        XCTAssertEqual(try Data(contentsOf: sample), Data([1, 2, 3, 4]))
    }

    func testRepeatedSFZRegionsImportOneManagedSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-dedupe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("tone.wav")
        let original = Data([0, 1, 2, 3, 4, 5])
        try original.write(to: source)
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
        try Data([1, 2, 3, 4]).write(to: sample)
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
