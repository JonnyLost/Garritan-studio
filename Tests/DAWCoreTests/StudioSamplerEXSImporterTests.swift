import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerEXSImporterTests: XCTestCase {
    private func u16(_ n: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)])
    }
    private func u32(_ n: UInt32) -> Data {
        u16(UInt16(truncatingIfNeeded: n)) +
        u16(UInt16(truncatingIfNeeded: n >> 16))
    }
    private func put(_ data: inout Data, _ at: Int, _ bytes: Data) {
        data.replaceSubrange(at..<(at + bytes.count), with: bytes)
    }
    private func named(_ string: String, _ count: Int) -> Data {
        var bytes = Data(string.utf8.prefix(count - 1))
        bytes.append(Data(repeating: 0, count: count - bytes.count))
        return bytes
    }
    private func block(_ kind: UInt8, name: String, index: UInt32,
                       body: Data) -> Data {
        precondition(body.count <= 0x7fff)
        var header = Data([1, 1, 0, kind])
        header.append(u16(UInt16(body.count)))
        header.append(u16(0))
        header.append(u32(index))
        header.append(u32(0))
        header.append(Data("TBOS".utf8))
        header.append(named(name, 64))
        precondition(header.count == 84)
        return header + body
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Studio-EXS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func wav(_ name: String, in folder: URL) throws -> URL {
        var audio = Data("RIFF".utf8)
        audio.append(u32(36 + 64 * 2))
        audio.append(contentsOf: Data("WAVEfmt ".utf8))
        audio.append(u32(16))
        audio.append(u16(1)) // 16-bit signed PCM
        audio.append(u16(1)) // mono
        audio.append(u32(44_100))
        audio.append(u32(88_200))
        audio.append(u16(2))
        audio.append(u16(16))
        audio.append(contentsOf: Data("data".utf8))
        audio.append(u32(64 * 2))
        for frame in 0..<64 {
            audio.append(u16(UInt16(truncatingIfNeeded: frame * 100)))
        }
        let url = folder.appendingPathComponent(name)
        try audio.write(to: url, options: .atomic)
        return url
    }
    private func fixture(in folder: URL, sampleName: String = "tone.wav",
                         zoneFlags: UInt8 = 8, sampleIndex: UInt32 = 0,
                         groupIndex: UInt32 = UInt32.max,
                         addGroup: Bool = false,
                         releaseTrigger: Bool = false,
                         groupEnable: UInt8 = 0,
                         loopOn: Bool = true,
                         zoneCount: Int = 1,
                         storedSamplePath: String = "") throws -> URL {
        let instrument = block(0, name: "EXS Test Instrument", index: 0,
                               body: Data(repeating: 0, count: 88))
        var zoneBytes = Data()
        for _ in 0..<zoneCount {
            var zone = Data(repeating: 0, count: 148)
            zone[0] = zoneFlags
            zone[1] = 60 // root
            zone[6] = 48 // low key
            zone[7] = 72 // high key
            zone[9] = 20 // low velocity
            zone[10] = 100 // high velocity
            put(&zone, 16, u32(64)) // end trim
            put(&zone, 20, u32(8))
            put(&zone, 24, u32(48))
            zone[33] = loopOn ? 1 : 0
            put(&zone, 88, u32(groupIndex))
            put(&zone, 92, u32(sampleIndex))
            zoneBytes.append(block(1, name: "Test Zone", index: 0, body: zone))
        }

        var groupBytes = Data()
        if addGroup {
            var group = Data(repeating: 0, count: 144)
            group[5] = 1
            group[6] = 127
            group[73] = releaseTrigger ? 1 : 0
            group[84] = groupEnable
            put(&group, 80, u32(UInt32.max))
            groupBytes = block(2, name: "Default Group", index: 0, body: group)
        }

        var sample = Data(repeating: 0, count: 592)
        put(&sample, 4, u32(64))
        put(&sample, 8, u32(44_100))
        put(&sample, 80, named(storedSamplePath, 256))
        put(&sample, 336, named(sampleName, 256))
        let sampleBytes = block(3, name: "Recorded Tone", index: 0, body: sample)
        let data = instrument + zoneBytes + groupBytes + sampleBytes
        let url = folder.appendingPathComponent("test.exs")
        try data.write(to: url, options: .atomic)
        return url
    }

    private struct GroupConfiguration {
        let name: String
        let type: UInt8
        let roundRobin: Int32
        let note: UInt8
        let controller: UInt8
        let ccLow: UInt8
        let ccHigh: UInt8

        init(_ name: String, type: UInt8,
             roundRobin: Int32 = -1, note: UInt8 = 0,
             controller: UInt8 = 0, ccLow: UInt8 = 0,
             ccHigh: UInt8 = 127) {
            self.name = name
            self.type = type
            self.roundRobin = roundRobin
            self.note = note
            self.controller = controller
            self.ccLow = ccLow
            self.ccHigh = ccHigh
        }
    }

    private func groupedFixture(in root: URL,
                                groups: [GroupConfiguration]) throws -> URL {
        guard groups.count >= 2 else { throw NSError(domain: "fixture", code: 1) }
        let instrument = block(0, name: "EXS Group Selection", index: 0,
                               body: Data(repeating: 0, count: 88))
        var zones = Data()
        var groupData = Data()
        var samples = Data()
        for (index, group) in groups.enumerated() {
            let name = "take-\(index).wav"
            _ = try wav(name, in: root)
            var zone = Data(repeating: 0, count: 148)
            zone[0] = 8 // use velocity limits
            zone[1] = 60
            zone[6] = 48
            zone[7] = 72
            zone[9] = 1
            zone[10] = 127
            put(&zone, 16, u32(64))
            put(&zone, 88, u32(UInt32(index)))
            put(&zone, 92, u32(UInt32(index)))
            zones.append(block(1, name: "EXS Zone \(index)", index: UInt32(index),
                               body: zone))

            var definition = Data(repeating: 0, count: 144)
            definition[5] = 1
            definition[6] = 127
            definition[75] = group.note
            definition[84] = group.type
            definition[85] = group.controller
            definition[86] = group.ccLow
            definition[87] = group.ccHigh
            put(&definition, 80, u32(UInt32(bitPattern: group.roundRobin)))
            groupData.append(block(2, name: group.name, index: UInt32(index),
                                   body: definition))

            var sample = Data(repeating: 0, count: 592)
            put(&sample, 4, u32(64))
            put(&sample, 8, u32(44_100))
            put(&sample, 336, named(name, 256))
            samples.append(block(3, name: "EXS Sample \(index)",
                                 index: UInt32(index), body: sample))
        }
        let url = root.appendingPathComponent("grouped.exs")
        try (instrument + zones + groupData + samples).write(to: url, options: .atomic)
        return url
    }

    func testRoundRobinGroupsBecomeNativeVariationTakes() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Take One", type: 2, roundRobin: 0),
            GroupConfiguration("Take Two", type: 2, roundRobin: 1)
        ])
        let preview = try StudioSamplerEXSImporter.preview(source)
        XCTAssertTrue(preview.patch.isValid)
        XCTAssertEqual(preview.patch.zones.map(\.roundRobinIndex), [0, 1])
        XCTAssertEqual(Set(preview.patch.zones.map(\.filePath)).count, 2)
        let output = try StudioSamplerEXSImporter.importInstrument(
            source, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(output.patch.zones.map(\.roundRobinIndex), [0, 1])
    }

    func testKeySelectedGroupsPreserveActualKeyswitchNotes() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Sustain", type: 1, note: 24),
            GroupConfiguration("Staccato", type: 1, note: 25)
        ])
        let result = try StudioSamplerEXSImporter.preview(source)
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.defaultKeyswitchNote, 24)
        XCTAssertEqual(result.patch.articulations?.count, 1)
        XCTAssertEqual(result.patch.articulations?[0].name, "Staccato")
        XCTAssertEqual(result.patch.articulations?[0].keyswitchNote, 25)
        XCTAssertEqual(result.patch.zones.map { $0.articulationID ?? 0 }, [0, 1])
        XCTAssertNil(result.patch.controllerSwitch)
    }

    func testRegularCC1GroupsBecomeNativeArticulationSelector() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Soft", type: 3, controller: 1, ccLow: 0, ccHigh: 63),
            GroupConfiguration("Loud", type: 3, controller: 1, ccLow: 64, ccHigh: 127)
        ])
        let result = try StudioSamplerEXSImporter.preview(source)
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.controllerSwitch?.controller, 1)
        XCTAssertEqual(result.patch.controllerSwitch?.articulationIDs, [0, 1])
        XCTAssertEqual(result.patch.zones.map { $0.articulationID ?? 0 }, [0, 1])
        let encoded = try JSONEncoder().encode(result.patch)
        let restored = try JSONDecoder().decode(StudioSamplerPatch.self, from: encoded)
        XCTAssertEqual(restored.controllerSwitch, result.patch.controllerSwitch)
    }

    func testIrregularEXSCCThresholdsAreRejectedWithoutCopying() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Soft", type: 3, controller: 1, ccLow: 0, ccHigh: 40),
            GroupConfiguration("Loud", type: 3, controller: 1, ccLow: 41, ccHigh: 127)
        ])
        let managed = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerEXSImporter.importInstrument(source, into: managed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
    }

    func testUnsupportedLogicArticulationIDsAreNotInventedAsKeyswitches() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Sustain", type: 6),
            GroupConfiguration("Marcato", type: 6)
        ])
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(source))
    }

    func testNonSequentialRoundRobinFailsSafely() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Take One", type: 2, roundRobin: 0),
            GroupConfiguration("Take Three", type: 2, roundRobin: 2)
        ])
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(source))
    }

    func testKeyswitchCollisionWithPlayableKeysFailsSafely() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try groupedFixture(in: root, groups: [
            GroupConfiguration("Sustain", type: 1, note: 60),
            GroupConfiguration("Staccato", type: 1, note: 61)
        ])
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(source))
    }

    func testInspectAndImportPreserveMappingAndSourceAudio() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try wav("tone.wav", in: root)
        let source = try fixture(in: root)
        let originalInstrument = try Data(contentsOf: source)
        let originalAudio = try Data(contentsOf: sample)
        let catalog = try StudioSamplerEXSReader.inspect(source)
        XCTAssertEqual(catalog.name, "EXS Test Instrument")
        XCTAssertEqual(catalog.zones.count, 1)
        XCTAssertEqual(catalog.samples.count, 1)
        let preview = try StudioSamplerEXSImporter.preview(source)
        XCTAssertEqual(preview.instrumentName, catalog.name)
        XCTAssertEqual(preview.patch.zones.count, 1)
        let zone = try XCTUnwrap(preview.patch.zones.first)
        XCTAssertEqual(zone.rootNote, 60)
        XCTAssertEqual(zone.lowestNote, 48)
        XCTAssertEqual(zone.highestNote, 72)
        XCTAssertEqual(zone.lowestVelocity, 20)
        XCTAssertEqual(zone.highestVelocity, 100)
        XCTAssertEqual(zone.loopStartFrame, 8)
        XCTAssertEqual(zone.loopEndFrame, 48)
        XCTAssertEqual(zone.sampleURL, sample)

        let target = root.appendingPathComponent("managed")
        let imported = try StudioSamplerEXSImporter.importInstrument(source, into: target)
        XCTAssertTrue(imported.patch.isValid)
        let installed = try XCTUnwrap(imported.patch.zones.first)
        XCTAssertNotEqual(installed.filePath, sample.path)
        XCTAssertNil(installed.managedFileName) // explicit test directory
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installed.filePath)),
                       originalAudio)
        XCTAssertEqual(try Data(contentsOf: sample), originalAudio)
        XCTAssertEqual(try Data(contentsOf: source), originalInstrument)
    }

    func testRepeatedSampleZonesUseOneManagedCopy() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try wav("tone.wav", in: root)
        let source = try fixture(in: root, zoneCount: 2)
        let target = root.appendingPathComponent("managed")
        let imported = try StudioSamplerEXSImporter.importInstrument(source, into: target)
        XCTAssertEqual(imported.patch.zones.count, 2)
        XCTAssertEqual(imported.patch.zones[0].filePath,
                       imported.patch.zones[1].filePath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: nil).count, 1)
    }

    func testBasicGroupVelocityAndReleaseTrigger() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try wav("tone.wav", in: root)
        let source = try fixture(in: root, groupIndex: 0,
                                 addGroup: true, releaseTrigger: true,
                                 loopOn: false)
        let result = try StudioSamplerEXSImporter.preview(source)
        XCTAssertEqual(result.patch.zones[0].isReleaseTrigger, true)
        XCTAssertNil(result.patch.zones[0].loopStartFrame)
    }

    func testRejectsAdvancedGroupsAndReversePlaybackWithoutCopying() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try wav("tone.wav", in: root)
        let target = root.appendingPathComponent("managed")
        let advanced = try fixture(in: root, groupIndex: 0,
                                   addGroup: true, groupEnable: 3)
        XCTAssertThrowsError(try StudioSamplerEXSImporter.importInstrument(
            advanced, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let reverse = try fixture(in: root, zoneFlags: 8 | 4)
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(reverse))
    }

    func testEXSAbsolutePathCannotReadOutsideSelectedFolderWithoutExplicitGrant() throws {
        let instrumentFolder = try folder()
        let externalFolder = try folder()
        defer {
            try? FileManager.default.removeItem(at: instrumentFolder)
            try? FileManager.default.removeItem(at: externalFolder)
        }
        let original = try wav("remote.wav", in: externalFolder)
        let instrument = try fixture(in: instrumentFolder, sampleName: "remote.wav",
                                     storedSamplePath: externalFolder.path)
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(instrument)) { error in
            guard case StudioSamplerEXSImporter.ImportError.missingAudio = error else {
                return XCTFail("Expected an explicit sample-folder grant requirement")
            }
        }
        let preview = try StudioSamplerEXSImporter.preview(
            instrument, samplesRoot: externalFolder)
        XCTAssertEqual(preview.patch.zones[0].sampleURL, original)
        let managed = instrumentFolder.appendingPathComponent("managed")
        let result = try StudioSamplerEXSImporter.importInstrument(
            instrument, into: managed, samplesRoot: externalFolder)
        XCTAssertEqual(result.patch.zones.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: managed, includingPropertiesForKeys: nil).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testEXSSymlinkOutsideInstrumentFolderCannotBypassGrant() throws {
        let instrumentFolder = try folder()
        let externalFolder = try folder()
        defer {
            try? FileManager.default.removeItem(at: instrumentFolder)
            try? FileManager.default.removeItem(at: externalFolder)
        }
        let external = try wav("tone.wav", in: externalFolder)
        let symlink = instrumentFolder.appendingPathComponent("tone.wav")
        try FileManager.default.createSymbolicLink(at: symlink,
                                                    withDestinationURL: external)
        let instrument = try fixture(in: instrumentFolder)
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(instrument))
        let restored = try StudioSamplerEXSImporter.preview(
            instrument, samplesRoot: externalFolder)
        XCTAssertEqual(restored.patch.zones[0].sampleURL, external)
    }

    func testEXSExplicitSampleFolderCanContainSamplesSubfolder() throws {
        let instrumentFolder = try folder()
        let externalFolder = try folder()
        defer {
            try? FileManager.default.removeItem(at: instrumentFolder)
            try? FileManager.default.removeItem(at: externalFolder)
        }
        let sampleFolder = externalFolder.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(at: sampleFolder,
                                                 withIntermediateDirectories: true)
        let original = try wav("tone.wav", in: sampleFolder)
        let instrument = try fixture(in: instrumentFolder)
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(instrument))
        let preview = try StudioSamplerEXSImporter.preview(
            instrument, samplesRoot: externalFolder)
        XCTAssertEqual(preview.patch.zones[0].sampleURL, original)
    }

    func testMissingAudioAndPathTraversalRejectBeforeImport() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try fixture(in: root, sampleName: "not-here.wav")
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(missing))
        let outside = try fixture(in: root, sampleName: "../escape.wav")
        XCTAssertThrowsError(try StudioSamplerEXSImporter.preview(outside))
    }

    func testMalformedBinaryAndMissingSampleReference() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.exs")
        try Data("not a valid EXS file".utf8).write(to: bad)
        XCTAssertThrowsError(try StudioSamplerEXSReader.inspect(bad))
        let sample = try wav("tone.wav", in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
        let invalid = try fixture(in: root, sampleIndex: 9)
        XCTAssertThrowsError(try StudioSamplerEXSReader.inspect(invalid))
        var truncated = try Data(contentsOf: invalid)
        truncated.removeLast(1)
        try truncated.write(to: invalid)
        XCTAssertThrowsError(try StudioSamplerEXSReader.inspect(invalid))
    }
}
