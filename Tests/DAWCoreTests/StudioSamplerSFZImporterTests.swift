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
