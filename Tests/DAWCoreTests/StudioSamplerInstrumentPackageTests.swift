import XCTest
import Foundation
@testable import DAWCore

final class StudioSamplerInstrumentPackageTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSamplerPackage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sample(_ name: String, in folder: URL, bytes: [UInt8]) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try Data(bytes).write(to: file)
        return file
    }

    func testPortableRoundTripPreservesMappingAndDeduplicatesSources() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try sample("SoloViolin_C4.wav", in: root, bytes: [1, 2, 3, 4, 5, 6])
        var zone = StudioSamplerZone(sampleURL: source)
        zone.trimStartFrame = 1
        zone.trimEndFrame = 128
        zone.loopStartFrame = 20
        zone.loopEndFrame = 90
        zone.loopCrossfadeFrames = 12
        zone.roundRobinIndex = 1
        zone.articulationID = 1
        var patch = StudioSamplerPatch(zones: [zone, zone])
        patch.cc1Crossfade = true
        patch.envelope = StudioSamplerEnvelope(attackSeconds: 0.15, decaySeconds: 0.2,
                                              sustainLevel: 0.75, releaseSeconds: 0.5)
        patch.articulations = [
            StudioSamplerArticulation(id: 1, name: "Legato", keyswitchNote: 24)
        ]
        XCTAssertTrue(patch.isValid)
        let metadata = StudioSamplerInstrumentPackage.Metadata(
            name: "Solo Violin", category: "Strings", tags: ["Orchestral", "Solo"])
        let bundle = root.appendingPathComponent("SoloViolin.studioinstrument")
        try StudioSamplerInstrumentPackage.export(patch, metadata: metadata, to: bundle)
        let sampleFiles = try FileManager.default.contentsOfDirectory(
            at: bundle.appendingPathComponent("Samples"), includingPropertiesForKeys: nil)
        XCTAssertEqual(sampleFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let installedSamples = root.appendingPathComponent("private-samples")
        let (restored, restoredMetadata) = try StudioSamplerInstrumentPackage.load(
            bundle, into: installedSamples)
        XCTAssertEqual(restoredMetadata, metadata)
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.zones.count, 2)
        XCTAssertEqual(restored.zones[0].filePath, restored.zones[1].filePath)
        XCTAssertNotEqual(restored.zones[0].filePath, source.path)
        XCTAssertEqual(restored.zones[0].loopStartFrame, 20)
        XCTAssertEqual(restored.zones[0].trimEndFrame, 128)
        XCTAssertEqual(restored.articulations, patch.articulations)
        XCTAssertEqual(restored.envelope, patch.envelope)
        XCTAssertEqual(try Data(contentsOf: restored.zones[0].sampleURL),
                       Data([1, 2, 3, 4, 5, 6]))
    }

    func testDamagedSampleDoesNotImportAnyRecording() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try sample("C4.wav", in: root, bytes: [1, 2, 3, 4])
        let patch = StudioSamplerPatch(sampleURL: file)
        let package = root.appendingPathComponent("Corrupted.studioinstrument")
        try StudioSamplerInstrumentPackage.export(
            patch, metadata: .init(name: "Damaged"), to: package)
        let recordings = package.appendingPathComponent("Samples")
        let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil).first)
        try Data([9, 9, 9, 9]).write(to: entry)
        let target = root.appendingPathComponent("private-samples")
        XCTAssertThrowsError(try StudioSamplerInstrumentPackage.load(package, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testLibraryCatalogFilteringAndRemovalLeaveSourceSamplesUntouched() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try self.sample("Piano_C4.wav", in: root, bytes: [11, 12, 13])
        let patches = StudioSamplerPatch(sampleURL: sample)
        let library = root.appendingPathComponent("instruments")
        let saved = try StudioSamplerInstrumentPackage.saveToLibrary(
            patches, metadata: .init(name: "Concert Piano", category: "Keys",
                                     tags: ["Warm", "Acoustic"]), in: library)
        let items = try StudioSamplerInstrumentPackage.listLibrary(in: library)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].metadata.name, "Concert Piano")
        XCTAssertEqual(items[0].metadata.category, "Keys")
        XCTAssertEqual(items[0].metadata.tags, ["Acoustic", "Warm"])
        XCTAssertEqual(items[0].zoneCount, 1)
        try StudioSamplerInstrumentPackage.removeFromLibrary(saved, in: library)
        XCTAssertTrue(try StudioSamplerInstrumentPackage.listLibrary(in: library).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
    }

    func testBadPathsAndDoubleExportsFailSafely() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try self.sample("C4.wav", in: root, bytes: [1, 2])
        let patch = StudioSamplerPatch(sampleURL: sample)
        let bundle = root.appendingPathComponent("Safe.studioinstrument")
        try StudioSamplerInstrumentPackage.export(patch, metadata: .init(name: "Safe"), to: bundle)
        XCTAssertThrowsError(try StudioSamplerInstrumentPackage.export(
            patch, metadata: .init(name: "Safe"), to: bundle))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertThrowsError(try StudioSamplerInstrumentPackage.removeFromLibrary(
            bundle, in: outside))
        // A forged manifest cannot use a relative traversal or external file.
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "Samples/000-C4.wav",
                                                     with: "Samples/../C4.wav")
        XCTAssertNotEqual(original, changed)
        try changed.write(to: manifestURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try StudioSamplerInstrumentPackage.load(
            bundle, into: root.appendingPathComponent("private-samples")))
    }
}
