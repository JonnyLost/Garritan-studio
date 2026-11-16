import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerGIGImporterTests: XCTestCase {
    private func u16(_ n: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)])
    }
    private func u32(_ n: UInt32) -> Data {
        u16(UInt16(truncatingIfNeeded: n)) +
            u16(UInt16(truncatingIfNeeded: n >> 16))
    }
    private func fourCC(_ text: String) -> Data { Data(text.utf8) }
    private func chunk(_ type: String, _ payload: Data) -> Data {
        var result = fourCC(type) + u32(UInt32(payload.count)) + payload
        if payload.count & 1 == 1 { result.append(0) }
        return result
    }
    private func list(_ type: String, _ nodes: [Data]) -> Data {
        chunk("LIST", fourCC(type) + nodes.reduce(into: Data()) { $0.append($1) })
    }
    private func parameters() -> Data {
        // DLS wsmp: header (20), unity note 60, 1 sustaining loop (2...8).
        u32(20) + u16(60) + u16(0) + u32(0) + u32(0) + u32(1) +
            u32(16) + u32(0) + u32(2) + u32(6)
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioGIG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        return root
    }
    private func fixture(in root: URL, dimensions: UInt32 = 1,
                         format: UInt16 = 1, gigSampleInfo: Bool = false) throws -> URL {
        let samples: [Int16] = [0, 1000, -1000, 250, -250,
                                 300, -300, 900, -900, 0, 0, 0]
        var pcm = Data()
        for sample in samples { pcm.append(u16(UInt16(bitPattern: sample))) }
        let info = list("INFO", [chunk("INAM", Data("GIG Test Instrument\0".utf8))])
        let fmt = u16(format) + u16(1) + u32(22_050) +
                  u32(44_100) + u16(2) + u16(16)
        let gigSmpl = u32(0) + u32(0) + u32(0) + u32(60) +
            u32(0) + u32(0) + u32(0) + u32(1) +
            u32(0) + u32(0) + u32(0) + u32(2) + u32(8) +
            Data(repeating: 0, count: 8)
        let wave = list("wave", [
            chunk("fmt ", fmt),
            chunk("data", pcm),
            gigSampleInfo ? chunk("smpl", gigSmpl) : chunk("wsmp", parameters()),
            list("INFO", [chunk("INAM", Data("Test Sample\0".utf8))])
        ])
        // GIG's 3lnk: number of dimension cases at offset 0, sample-table
        // indices at offset 44 (one per dimension).
        let dimensionLinks = u32(dimensions) +
            Data(repeating: 0, count: 40) +
            (0..<dimensions).reduce(into: Data()) { bytes, _ in
                bytes.append(u32(0))
            }
        let dimensionLists = (0..<dimensions).map { _ in
            list("3ewl", [chunk("wsmp", parameters())])
        }
        let region = list("rgn ", [
            chunk("rgnh", u16(48) + u16(72) +
                              u16(1) + u16(127) + u16(0) + u16(0)),
            chunk("3lnk", dimensionLinks),
            list("3prg", dimensionLists)
        ])
        let instrument = list("ins ", [
            chunk("insh", u32(1) + u32(2) + u32(4)),
            info,
            list("lrgn", [region])
        ])
        let payload = fourCC("DLS ") +
            list("lins", [instrument]) +
            chunk("ptbl", u32(8) + u32(1) + u32(0)) +
            list("wvpl", [wave])
        let url = root.appendingPathComponent("StudioFixture.gig")
        try (fourCC("RIFF") + u32(UInt32(payload.count)) + payload)
            .write(to: url, options: .atomic)
        return url
    }

    func testGIGCatalogAndPlayablePCMImport() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root)
        let original = try Data(contentsOf: gig)
        let catalog = try StudioSamplerGIGReader.inspect(gig)
        XCTAssertEqual(catalog.instruments.count, 1)
        XCTAssertEqual(catalog.waves.count, 1)
        XCTAssertEqual(catalog.sampleIndexToWave[0], 0)
        XCTAssertEqual(catalog.instruments[0].name, "GIG Test Instrument")
        XCTAssertEqual(catalog.instruments[0].bank, 2)
        XCTAssertEqual(catalog.instruments[0].program, 4)
        XCTAssertEqual(catalog.instruments[0].regions.count, 1)
        XCTAssertEqual(catalog.instruments[0].regions[0].dimensionCount, 1)

        let preview = try StudioSamplerGIGImporter.preview(gig, instrumentIndex: 0)
        XCTAssertEqual(preview.regionCount, 1)
        let target = root.appendingPathComponent("managed")
        let imported = try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: target)
        XCTAssertTrue(imported.patch.isValid)
        XCTAssertEqual(imported.patch.zones.count, 1)
        let zone = try XCTUnwrap(imported.patch.zones.first)
        XCTAssertEqual(zone.lowestNote, 48)
        XCTAssertEqual(zone.highestNote, 72)
        XCTAssertEqual(zone.rootNote, 60)
        XCTAssertEqual(zone.loopStartFrame, 2)
        XCTAssertEqual(zone.loopEndFrame, 8)
        XCTAssertNil(zone.managedFileName) // custom test directory
        let wav = try Data(contentsOf: URL(fileURLWithPath: zone.filePath))
        XCTAssertEqual(wav.count, 44 + 24)
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(wav[22..<24]), [1, 0])
        XCTAssertEqual(Array(wav[44..<48]), [0, 0, 0xe8, 0x03])
        XCTAssertEqual(try Data(contentsOf: gig), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: nil).count, 1)
    }

    func testGIGSmplWaveMetadataReadsPitchAndLoops() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, gigSampleInfo: true)
        let catalog = try StudioSamplerGIGReader.inspect(gig)
        XCTAssertEqual(catalog.waves[0].parameters?.root, 60)
        XCTAssertEqual(catalog.waves[0].parameters?.loopStart, 2)
        XCTAssertEqual(catalog.waves[0].parameters?.loopEnd, 8)
        let result = try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(result.patch.zones[0].loopStartFrame, 2)
        XCTAssertEqual(result.patch.zones[0].loopEndFrame, 8)
    }

    func testMultipleGigDimensionsAreRejectedRatherThanFlattened() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, dimensions: 2)
        let catalog = try StudioSamplerGIGReader.inspect(gig)
        XCTAssertEqual(catalog.instruments[0].regions[0].dimensionCount, 2)
        let destination = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: destination)) { error in
            guard case StudioSamplerGIGImporter.ImportError.unsupportedDimensions = error else {
                return XCTFail("Expected explicit unsupported-dimensions error")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsNonPCMWithoutInstallingSamples() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, format: 3)
        let destination = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsInvalidRiffAndTruncatedChunks() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("invalid.gig")
        try Data("invalid container".utf8).write(to: bad)
        XCTAssertThrowsError(try StudioSamplerGIGReader.inspect(bad))

        let valid = try fixture(in: root)
        var damaged = try Data(contentsOf: valid)
        // Break RIFF's declared top-level length.
        damaged[4] = 0xff
        damaged[5] = 0xff
        damaged[6] = 0xff
        damaged[7] = 0x7f
        try damaged.write(to: valid)
        XCTAssertThrowsError(try StudioSamplerGIGReader.inspect(valid))
    }
}
