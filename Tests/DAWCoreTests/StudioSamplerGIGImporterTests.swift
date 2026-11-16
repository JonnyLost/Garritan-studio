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
                         format: UInt16 = 1, gigSampleInfo: Bool = false,
                         definitions: [(UInt8, UInt8)] = [],
                         keyswitchRange: ClosedRange<UInt8>? = nil,
                         explicitFirstDimensionZones: UInt8 = 0) throws -> URL {
        let sampleFrames: [Int16] = [0, 1000, -1000, 250, -250,
                                     300, -300, 900, -900, 0, 0, 0]
        let fmt = u16(format) + u16(1) + u32(22_050) +
                  u32(44_100) + u16(2) + u16(16)
        let gigSmpl = u32(0) + u32(0) + u32(0) + u32(60) +
            u32(0) + u32(0) + u32(0) + u32(1) +
            u32(0) + u32(0) + u32(0) + u32(2) + u32(8) +
            Data(repeating: 0, count: 8)

        // Every dimension case references a distinct uncompressed recording.
        // Pool cues are byte offsets from the first wvpl subchunk.
        var waveBytes = Data()
        var poolOffsets: [UInt32] = []
        for caseIndex in 0..<Int(dimensions) {
            poolOffsets.append(UInt32(waveBytes.count))
            var pcm = Data()
            for sample in sampleFrames {
                pcm.append(u16(UInt16(bitPattern: sample + Int16(caseIndex))))
            }
            let wave = list("wave", [
                chunk("fmt ", fmt), chunk("data", pcm),
                gigSampleInfo ? chunk("smpl", gigSmpl) : chunk("wsmp", parameters()),
                list("INFO", [chunk("INAM", Data("Test Sample \0".utf8))])
            ])
            waveBytes.append(wave)
        }
        let wvpl = chunk("LIST", fourCC("wvpl") + waveBytes)
        let info = list("INFO", [chunk("INAM", Data("GIG Test Instrument\0".utf8))])

        let declaredDefinitions = definitions.isEmpty && dimensions > 1
            ? [(UInt8(0x81), UInt8(1))] : definitions
        var dimensionHeader = u32(dimensions)
        var dimensionBitPosition = 0
        for index in 0..<5 {
            if index < declaredDefinitions.count {
                let bits = declaredDefinitions[index].1
                dimensionHeader.append(declaredDefinitions[index].0)
                dimensionHeader.append(bits)
                dimensionHeader.append(UInt8(dimensionBitPosition))
                dimensionHeader.append(0) // dimension bit mask (unused by reader)
                dimensionHeader.append(index == 0
                    ? explicitFirstDimensionZones : 0) // 0 means 2^bits zones
                dimensionHeader.append(Data(repeating: 0, count: 3))
                dimensionBitPosition += Int(bits)
            } else {
                dimensionHeader.append(Data(repeating: 0, count: 8))
            }
        }
        for caseIndex in 0..<32 {
            dimensionHeader.append(caseIndex < Int(dimensions)
                                   ? u32(UInt32(caseIndex)) : u32(UInt32.max))
        }
        XCTAssertEqual(dimensionHeader.count, 172)
        let dimensionLists = (0..<dimensions).map { _ in
            list("3ewl", [chunk("wsmp", parameters())])
        }
        let region = list("rgn ", [
            chunk("rgnh", u16(48) + u16(72) +
                              u16(1) + u16(127) + u16(0) + u16(0)),
            chunk("3lnk", dimensionHeader),
            list("3prg", dimensionLists)
        ])
        var instrumentNodes = [
            chunk("insh", u32(1) + u32(2) + u32(4)),
            info, list("lrgn", [region])
        ]
        if let keys = keyswitchRange {
            let settings = u16(0) + u32(0) + u16(0) + u16(2) +
                Data([keys.lowerBound << 1, keys.upperBound]) +
                Data(repeating: 0, count: 20)
            instrumentNodes.append(list("lart", [chunk("3ewg", settings)]))
        }
        let instrument = list("ins ", instrumentNodes)
        let cues = poolOffsets.reduce(into: Data()) { $0.append(u32($1)) }
        let payload = fourCC("DLS ") +
            list("lins", [instrument]) +
            chunk("ptbl", u32(8) + u32(dimensions) + cues) + wvpl
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

    func testVelocityDimensionCreatesDistinctNativeVelocityLayers() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, dimensions: 2,
                              definitions: [(0x82, 1)])
        let catalog = try StudioSamplerGIGReader.inspect(gig)
        let region = catalog.instruments[0].regions[0]
        XCTAssertEqual(region.dimensions.map(\.type), [0x82])
        XCTAssertEqual(region.cases.count, 2)
        XCTAssertEqual(region.cases.compactMap(\.sampleTableIndex), [0, 1])
        let imported = try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(imported.patch.zones.map(\.lowestVelocity), [1, 64])
        XCTAssertEqual(imported.patch.zones.map(\.highestVelocity), [63, 127])
        XCTAssertTrue(imported.patch.zones.allSatisfy { $0.roundRobinIndex == nil })
        XCTAssertEqual(Set(imported.patch.zones.map(\.filePath)).count, 2)
        XCTAssertTrue(imported.patch.isValid)
    }

    func testRoundRobinDimensionCreatesNativeAlternateTakes() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, dimensions: 2,
                              definitions: [(0x86, 1)])
        let imported = try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(imported.patch.zones.map(\.roundRobinIndex), [0, 1])
        XCTAssertEqual(imported.patch.zones.map(\.lowestVelocity), [1, 1])
        XCTAssertEqual(imported.patch.zones.map(\.highestVelocity), [127, 127])
        XCTAssertTrue(imported.patch.isValid)
    }

    func testCombinedVelocityAndRoundRobinDimensionsKeepCaseOrdering() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, dimensions: 4,
                              definitions: [(0x82, 1), (0x86, 1)])
        let imported = try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(imported.patch.zones.map(\.lowestVelocity), [1, 64, 1, 64])
        XCTAssertEqual(imported.patch.zones.map(\.highestVelocity), [63, 127, 63, 127])
        XCTAssertEqual(imported.patch.zones.map(\.roundRobinIndex), [0, 0, 1, 1])
        XCTAssertEqual(Set(imported.patch.zones.map(\.filePath)).count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("managed"), includingPropertiesForKeys: nil).count, 4)
    }

    func testReleaseDimensionCreatesNoteOffZoneWithoutSustainLoop() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, dimensions: 2,
                              definitions: [(0x84, 1)])
        let imported = try StudioSamplerGIGImporter.importInstrument(
            gig, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(imported.patch.zones.count, 2)
        XCTAssertNil(imported.patch.zones[0].isReleaseTrigger)
        XCTAssertEqual(imported.patch.zones[0].loopStartFrame, 2)
        XCTAssertEqual(imported.patch.zones[1].isReleaseTrigger, true)
        XCTAssertNil(imported.patch.zones[1].loopStartFrame)
        XCTAssertTrue(imported.patch.isValid)
    }

    func testKeyboardDimensionPreservesGIGKeyswitchRangeAndArticulations() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, dimensions: 2,
            definitions: [(0x85, 1)], keyswitchRange: 24...25)
        let catalog = try StudioSamplerGIGReader.inspect(source)
        XCTAssertEqual(catalog.instruments[0].keyswitchRange, 24...25)
        let result = try StudioSamplerGIGImporter.importInstrument(
            source, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.defaultKeyswitchNote, 24)
        XCTAssertEqual(result.patch.articulations?.count, 1)
        XCTAssertEqual(result.patch.articulations?[0].keyswitchNote, 25)
        XCTAssertEqual(result.patch.articulations?[0].id, 1)
        XCTAssertEqual(result.patch.zones.map { $0.articulationID ?? 0 }, [0, 1])
        XCTAssertNil(result.patch.controllerSwitch)
    }

    func testCC1DimensionConvertsToDiscreteControllerArticulationGroups() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, dimensions: 2,
            definitions: [(0x01, 1)])
        let result = try StudioSamplerGIGImporter.importInstrument(
            source, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.controllerSwitch?.controller, 1)
        XCTAssertEqual(result.patch.controllerSwitch?.articulationIDs, [0, 1])
        XCTAssertNil(result.patch.defaultKeyswitchNote)
        XCTAssertEqual(result.patch.zones.map { $0.articulationID ?? 0 }, [0, 1])
        let encoded = try JSONEncoder().encode(result.patch)
        let restored = try JSONDecoder().decode(StudioSamplerPatch.self, from: encoded)
        XCTAssertEqual(restored, result.patch)
        XCTAssertEqual(restored.controllerSwitch?.articulationIDs, [0, 1])
    }

    func testCC2DimensionAndVelocityStayIndependent() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, dimensions: 4,
            definitions: [(0x82, 1), (0x02, 1)])
        let result = try StudioSamplerGIGImporter.importInstrument(
            source, instrumentIndex: 0, into: root.appendingPathComponent("managed"))
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.controllerSwitch?.controller, 2)
        XCTAssertEqual(result.patch.zones.map { $0.articulationID ?? 0 }, [0, 0, 1, 1])
        XCTAssertEqual(result.patch.zones.map(\.lowestVelocity), [1, 64, 1, 64])
        XCTAssertEqual(result.patch.zones.map(\.highestVelocity), [63, 127, 63, 127])
    }

    func testUnsupportedKeyswitchConfigurationFailsBeforeFileCopy() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, dimensions: 2,
            definitions: [(0x85, 1)]) // no 3ewg switch notes
        let destination = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerGIGImporter.importInstrument(
            source, instrumentIndex: 0, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testKeyswitchAndLayerDimensionsAreNotFlattenedIntoWrongInstruments() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for dimensionType in [UInt8(0x81), 0x85, 0x87] {
            let gig = try fixture(in: root, dimensions: 2,
                                  definitions: [(dimensionType, 1)])
            let destination = root.appendingPathComponent("managed")
            XCTAssertThrowsError(try StudioSamplerGIGImporter.importInstrument(
                gig, instrumentIndex: 0, into: destination)) { error in
                guard case StudioSamplerGIGImporter.ImportError.unsupportedDimensions = error else {
                    return XCTFail("Expected explicit unsupported-dimensions error")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testControllerSelectionValidatesSupportedCCNumbersAndUniqueIDs() throws {
        XCTAssertTrue(StudioSamplerControllerSwitch(
            controller: 1, articulationIDs: [0, 1]).isValid)
        XCTAssertTrue(StudioSamplerControllerSwitch(
            controller: 2, articulationIDs: [0, 2, 3]).isValid)
        XCTAssertFalse(StudioSamplerControllerSwitch(
            controller: 7, articulationIDs: [0, 1]).isValid)
        XCTAssertFalse(StudioSamplerControllerSwitch(
            controller: 1, articulationIDs: [0, 0]).isValid)
        XCTAssertFalse(StudioSamplerControllerSwitch(
            controller: 1, articulationIDs: [1, 0]).isValid)
    }

    func testNonPowerOfTwoDeclaredControllerSplitsFailSafely() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, dimensions: 4,
            definitions: [(0x01, 2)], explicitFirstDimensionZones: 3)
        let catalog = try StudioSamplerGIGReader.inspect(source)
        XCTAssertEqual(catalog.instruments[0].regions[0].dimensions[0].zoneCount, 3)
        let destination = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerGIGImporter.importInstrument(
            source, instrumentIndex: 0, into: destination)) { error in
            guard case StudioSamplerGIGImporter.ImportError.unsupportedDimensions = error else {
                return XCTFail("Expected safe rejection of irregular controller bands")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMalformedDimensionDefinitionsRejectedBeforeSampleIO() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gig = try fixture(in: root, dimensions: 2,
                              definitions: [(0x82, 1)])
        var data = try Data(contentsOf: gig)
        let chunkID = Data("3lnk".utf8)
        guard let location = data.range(of: chunkID)?.lowerBound else {
            return XCTFail("Fixture has no 3lnk chunk")
        }
        // Two cases require exactly one defined bit; invalidate the case
        // count without changing chunk sizes.
        data[location + 8] = 4
        try data.write(to: gig, options: .atomic)
        XCTAssertThrowsError(try StudioSamplerGIGReader.inspect(gig))
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
