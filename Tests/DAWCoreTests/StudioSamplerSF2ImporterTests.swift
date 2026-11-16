import Foundation
import XCTest
@testable import DAWCore

/// Tiny synthetic SoundFont fixtures avoid test dependencies on copyrighted
/// libraries and exercise actual RIFF preset/instrument/sample relationships.
final class StudioSamplerSF2ImporterTests: XCTestCase {
    private func u16(_ n: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)])
    }
    private func u32(_ n: UInt32) -> Data {
        u16(UInt16(truncatingIfNeeded: n)) + u16(UInt16(truncatingIfNeeded: n >> 16))
    }
    private func tag(_ name: String) -> Data { Data(name.utf8) }
    private func fixedName(_ name: String, size: Int) -> Data {
        var bytes = Data(name.utf8.prefix(size))
        bytes.append(Data(repeating: 0, count: size - bytes.count))
        return bytes
    }
    private func chunk(_ tagName: String, _ payload: Data) -> Data {
        var result = tag(tagName) + u32(UInt32(payload.count)) + payload
        if payload.count % 2 == 1 { result.append(0) }
        return result
    }
    private func list(_ kind: String, _ chunks: [Data]) -> Data {
        chunk("LIST", tag(kind) + chunks.reduce(into: Data()) { $0.append($1) })
    }
    private func generator(_ opcode: UInt16, _ amount: UInt16) -> Data {
        u16(opcode) + u16(amount)
    }
    private func range(_ low: UInt16, _ high: UInt16) -> UInt16 {
        low | (high << 8)
    }
    private func header(_ name: String, start: UInt32, end: UInt32,
                        loopStart: UInt32, loopEnd: UInt32,
                        link: UInt16 = 0, type: UInt16 = 1) -> Data {
        var bytes = fixedName(name, size: 20)
        for field in [u32(start), u32(end), u32(loopStart), u32(loopEnd),
                      u32(44_100), Data([60, 0]), u16(link), u16(type)] {
            bytes.append(field)
        }
        return bytes
    }

    private func fixture(in root: URL, stereo: Bool = false,
                         invalidReference: Bool = false) throws -> URL {
        let frames: [Int16] = [0, 1000, -1000, 300, 700, -700,
                               500, -500, 100, 0, 0, 0]
        var pcm = Data()
        for frame in frames { pcm.append(u16(UInt16(bitPattern: frame))) }
        if stereo {
            for frame in frames { pcm.append(u16(UInt16(bitPattern: -frame))) }
        }

        // Preset bag 0 -> instrument 0, terminal bag 1.
        var phdr = fixedName("Studio Test Preset", size: 20)
        for field in [u16(4), u16(7), u16(0),
                      u32(0), u32(0), u32(0),
                      fixedName("EOP", size: 20),
                      u16(0), u16(0), u16(1),
                      u32(0), u32(0), u32(0)] {
            phdr.append(field)
        }
        let pbag = u16(0) + u16(0) + u16(2) + u16(0)
        let pgen = generator(43, range(55, 72)) + generator(41, 0) +
                   generator(0, 0)
        let inst = fixedName("Studio Test Instrument", size: 20) + u16(0) +
                   fixedName("EOI", size: 20) + u16(1)
        let ibag = u16(0) + u16(0) + u16(4) + u16(0)
        let igen = generator(43, range(48, 84)) +
                   generator(44, range(20, 100)) +
                   generator(54, 1) +
                   generator(53, invalidReference ? 99 : 0) +
                   generator(0, 0)
        var sampleHeaders = header("Studio Mono", start: 0, end: 12,
                                   loopStart: 2, loopEnd: 10,
                                   link: stereo ? 1 : 0, type: stereo ? 4 : 1)
        if stereo {
            sampleHeaders.append(header("Studio Right", start: 12, end: 24,
                                        loopStart: 14, loopEnd: 22,
                                        link: 0, type: 2))
        }
        sampleHeaders.append(Data(repeating: 0, count: 46))
        let pdta = list("pdta", [
            chunk("phdr", phdr), chunk("pbag", pbag),
            chunk("pmod", Data(repeating: 0, count: 10)),
            chunk("pgen", pgen), chunk("inst", inst),
            chunk("ibag", ibag), chunk("imod", Data(repeating: 0, count: 10)),
            chunk("igen", igen), chunk("shdr", sampleHeaders)
        ])
        let soundfont = list("sdta", [chunk("smpl", pcm)])
        let payload = tag("sfbk") + soundfont + pdta
        let url = root.appendingPathComponent("fixture.sf2")
        try (tag("RIFF") + u32(UInt32(payload.count)) + payload)
            .write(to: url, options: .atomic)
        return url
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSF2Import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        return root
    }

    func testPresetToNativeZoneAndPCMExtraction() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let original = try Data(contentsOf: source)
        let preview = try StudioSamplerSF2Importer.preview(source, presetIndex: 0)
        XCTAssertEqual(preview.preset.name, "Studio Test Preset")
        XCTAssertEqual(preview.preset.bank, 7)
        XCTAssertEqual(preview.preset.program, 4)
        XCTAssertEqual(preview.zoneCount, 1)

        let destination = root.appendingPathComponent("managed")
        let result = try StudioSamplerSF2Importer.importInstrument(
            source, presetIndex: 0, into: destination)
        XCTAssertTrue(result.patch.isValid)
        XCTAssertEqual(result.patch.zones.count, 1)
        let zone = try XCTUnwrap(result.patch.zones.first)
        XCTAssertEqual(zone.lowestNote, 55)
        XCTAssertEqual(zone.highestNote, 72)
        XCTAssertEqual(zone.lowestVelocity, 20)
        XCTAssertEqual(zone.highestVelocity, 100)
        XCTAssertEqual(zone.rootNote, 60)
        XCTAssertEqual(zone.loopStartFrame, 2)
        XCTAssertEqual(zone.loopEndFrame, 10)
        XCTAssertNil(zone.managedFileName) // Custom test directory, not app-owned.
        let wav = try Data(contentsOf: URL(fileURLWithPath: zone.filePath))
        XCTAssertEqual(wav.count, 44 + 12 * 2)
        XCTAssertEqual(Array(wav.prefix(4)), Array(Data("RIFF".utf8)))
        XCTAssertEqual(Array(wav[44..<48]), [0, 0, 0xE8, 0x03])
        XCTAssertEqual(try Data(contentsOf: source), original)
        let imported = try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(imported.count, 1)
        try StudioSamplerExternalFormatRoundTrip.assertPreserved(
            result.patch, in: root, name: "SF2-Mono")
    }

    func testLinkedStereoExtractsInterleavedTwoChannelWave() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, stereo: true)
        let result = try StudioSamplerSF2Importer.importInstrument(
            source, presetIndex: 0, into: root.appendingPathComponent("managed"))
        let zone = try XCTUnwrap(result.patch.zones.first)
        let wav = try Data(contentsOf: URL(fileURLWithPath: zone.filePath))
        XCTAssertEqual(wav.count, 44 + 12 * 4)
        XCTAssertEqual(Array(wav[22..<24]), [2, 0])
        XCTAssertEqual(Array(wav[48..<52]), [0xE8, 0x03, 0x18, 0xFC])
        try StudioSamplerExternalFormatRoundTrip.assertPreserved(
            result.patch, in: root, name: "SF2-Stereo")
    }

    func testInvalidSampleReferenceDoesNotInstallAnything() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, invalidReference: true)
        let destination = root.appendingPathComponent("managed")
        XCTAssertThrowsError(try StudioSamplerSF2Importer.importInstrument(
            source, presetIndex: 0, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsMissingPreset() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        XCTAssertThrowsError(try StudioSamplerSF2Importer.preview(source, presetIndex: 17))
    }
}
