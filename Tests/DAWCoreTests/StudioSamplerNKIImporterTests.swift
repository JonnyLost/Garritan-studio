import Foundation
import XCTest
@testable import DAWCore

/// Original Kontakt K2-XML compatibility fixtures, not commercial content.
/// The NKI body is a standards-compliant RFC1950 stream of stored DEFLATE
/// blocks (RFC1951); no Kontakt runtime or compression plugin is used.
final class StudioSamplerNKIImporterTests: XCTestCase {
    private func u16(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value),
              UInt8(truncatingIfNeeded: value >> 8)])
    }
    private func u32(_ value: UInt32) -> Data {
        u16(UInt16(truncatingIfNeeded: value)) +
        u16(UInt16(truncatingIfNeeded: value >> 16))
    }
    private func checksum(_ data: Data) -> UInt32 {
        let prime: UInt32 = 65_521
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % prime
            b = (b + a) % prime
        }
        return b << 16 | a
    }
    private func archive(_ document: Data) -> Data {
        // A portable zlib (RFC1950) stream consisting of one or more
        // uncompressed raw DEFLATE blocks. This tests the production reader
        // with externally valid data independent of a compression encoder.
        var bytes = Data(repeating: 0, count: 170)
        bytes.append(contentsOf: [0x78, 0x01])
        var position = 0
        repeat {
            let count = min(65_535, document.count - position)
            let final = position + count == document.count
            bytes.append(final ? 1 : 0)
            bytes.append(u16(UInt16(count)))
            bytes.append(u16(~UInt16(count)))
            if count > 0 { bytes.append(document[position..<(position + count)]) }
            position += count
        } while position < document.count
        let adler = checksum(document)
        bytes.append(contentsOf: [
            UInt8(truncatingIfNeeded: adler >> 24),
            UInt8(truncatingIfNeeded: adler >> 16),
            UInt8(truncatingIfNeeded: adler >> 8),
            UInt8(truncatingIfNeeded: adler)
        ])
        return bytes
    }
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioNKI-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }
    private func wav(_ name: String, in root: URL) throws -> URL {
        let frames = 128
        var audio = Data("RIFF".utf8)
        audio.append(u32(UInt32(36 + frames * 2)))
        audio.append(Data("WAVEfmt ".utf8))
        audio.append(u32(16))
        audio.append(u16(1))
        audio.append(u16(1))
        audio.append(u32(44_100))
        audio.append(u32(88_200))
        audio.append(u16(2))
        audio.append(u16(16))
        audio.append(Data("data".utf8))
        audio.append(u32(UInt32(frames * 2)))
        for i in 0..<frames {
            audio.append(u16(UInt16(truncatingIfNeeded: i * 19)))
        }
        let url = root.appendingPathComponent(name)
        try audio.write(to: url, options: .atomic)
        return url
    }

    private func zoneXML(sample: String = "Samples/tone.wav",
                         low: Int = 48, high: Int = 72,
                         lowVelocity: Int = 1, highVelocity: Int = 127,
                         loop: Bool = true) -> String {
        """
        <Zone>
          <V name="rootKey" value="60"/>
          <V name="lowKey" value="\(low)"/>
          <V name="highKey" value="\(high)"/>
          <V name="lowVelo" value="\(lowVelocity)"/>
          <V name="highVelo" value="\(highVelocity)"/>
          <V name="sampleFile" value="\(sample)"/>
          <V name="sampleStart" value="4"/>
          <V name="sampleEnd" value="96"/>
          <V name="loopMode" value="\(loop ? 1 : 0)"/>
          <V name="loopStart" value="24"/>
          <V name="loopEnd" value="68"/>
        </Zone>
        """
    }

    private func document(zones: [String], script: Bool = false,
                          extraProgram: Bool = false,
                          groupRelease: Bool = false) -> String {
        let content = zones.joined(separator: "\n")
        let program = """
          <K2_Program name="Kontakt Test Piano" index="0">
            <Parameters>
              <V name="lowKey" value="40"/>
              <V name="highKey" value="90"/>
              <V name="lowVelocity" value="1"/>
              <V name="highVelocity" value="120"/>
            </Parameters>
            <Groups>
              <K2_Group index="0" name="Main Recordings">
                <Parameters>
                  <V name="lowVelocity" value="8"/>
                  <V name="highVelocity" value="127"/>
                  <V name="releaseTrigger" value="\(groupRelease ? "yes" : "no")"/>
                </Parameters>
                <Zones>
                \(content)
                </Zones>
              </K2_Group>
            </Groups>
          </K2_Program>
        """
        return """
        <?xml version="1.0"?>
        <K2_Container type="single_program" version="0.50">
          <Programs>
          \(program)
          \(extraProgram ? program : "")
          </Programs>
          \(script ? "<Script><Code>on note</Code></Script>" : "")
        </K2_Container>
        """
    }
    @discardableResult
    private func nki(_ text: String, in root: URL) throws -> URL {
        let target = root.appendingPathComponent("legacy.nki")
        try archive(Data(text.utf8)).write(to: target, options: .atomic)
        return target
    }

    func testLegacyK2NKIMapsExternalSamplesToPlayableStudioZones() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = root.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(
            at: samples, withIntermediateDirectories: true)
        let audioURL = try wav("tone.wav", in: samples)
        let source = try nki(document(zones: [
            zoneXML(lowVelocity: 1, highVelocity: 63),
            zoneXML(lowVelocity: 64, highVelocity: 127)
        ]), in: root)
        let originalNKI = try Data(contentsOf: source)
        let originalAudio = try Data(contentsOf: audioURL)

        let catalog = try StudioSamplerNKIReader.inspect(source)
        XCTAssertEqual(catalog.name, "Kontakt Test Piano")
        XCTAssertEqual(catalog.zones.count, 2)
        XCTAssertEqual(catalog.zones.map(\.lowVelocity), [8, 64])
        XCTAssertEqual(catalog.zones.map(\.highVelocity), [63, 120])
        XCTAssertEqual(catalog.zones[0].sampleStart, 4)
        XCTAssertEqual(catalog.zones[0].sampleEnd, 96)
        XCTAssertEqual(catalog.zones[0].loopStart, 24)
        XCTAssertEqual(catalog.zones[0].loopEnd, 68)

        let imported = try StudioSamplerNKIImporter.importInstrument(
            source, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(imported.name, "Kontakt Test Piano")
        XCTAssertTrue(imported.patch.isValid)
        XCTAssertEqual(imported.patch.zones.map(\.lowestVelocity), [8, 64])
        XCTAssertEqual(imported.patch.zones.map(\.highestVelocity), [63, 120])
        XCTAssertEqual(imported.patch.zones[0].trimStartFrame, 4)
        XCTAssertEqual(imported.patch.zones[0].trimEndFrame, 96)
        XCTAssertEqual(imported.patch.zones[0].loopStartFrame, 24)
        XCTAssertEqual(imported.patch.zones[0].loopEndFrame, 68)
        XCTAssertEqual(Set(imported.patch.zones.map(\.filePath)).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("managed"),
            includingPropertiesForKeys: nil).count, 1)
        XCTAssertEqual(try Data(contentsOf: source), originalNKI)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalAudio)
        try StudioSamplerExternalFormatRoundTrip.assertPreserved(
            imported.patch, in: root, name: "NKI-Legacy")
    }

    func testKontaktReleaseTriggerGroupsMapToNativeNoteOffSamples() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = root.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(
            at: samples, withIntermediateDirectories: true)
        _ = try wav("tone.wav", in: samples)
        let source = try nki(document(zones: [
            zoneXML(loop: false)
        ], groupRelease: true), in: root)
        let result = try StudioSamplerNKIImporter.preview(source)
        XCTAssertEqual(result.patch.zones[0].isReleaseTrigger, true)
        XCTAssertNil(result.patch.zones[0].loopStartFrame)
    }

    func testXMLDTDAndInternalEntityExpansionAreRejected() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = """
        <?xml version="1.0"?>
        <!DOCTYPE K2_Container [<!ENTITY infinite "explosion">]>
        <K2_Container><Programs><K2_Program name="Unsafe"/></Programs></K2_Container>
        """
        let file = try nki(content, in: root)
        XCTAssertThrowsError(try StudioSamplerNKIReader.inspect(file))
    }

    func testMissingExternalAudioCanBeRelinkedThroughExplicitSampleFolder() throws {
        let root = try temp()
        let external = try temp()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let expected = try wav("piano.wav", in: external)
        let source = try nki(document(zones: [
            zoneXML(sample: "piano.wav", loop: false)
        ]), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source))
        let result = try StudioSamplerNKIImporter.preview(
            source, samplesRoot: external)
        XCTAssertEqual(result.patch.zones[0].sampleURL, expected)
    }

    func testOutsideAbsolutePathsAndEscapingSymlinksAreNotTrusted() throws {
        let root = try temp()
        let external = try temp()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let outside = try wav("tone.wav", in: external)
        let source = try nki(document(zones: [
            zoneXML(sample: outside.path, loop: false)
        ]), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source))
        let explicit = try StudioSamplerNKIImporter.preview(
            source, samplesRoot: external)
        XCTAssertEqual(explicit.patch.zones[0].sampleURL, outside)

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("tone.wav"),
            withDestinationURL: outside)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source))
    }

    func testNKIRejectsAdvancedScriptingAndMultiplePrograms() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try nki(document(zones: [zoneXML()], script: true), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIReader.inspect(
            root.appendingPathComponent("legacy.nki")))
        _ = try nki(document(zones: [zoneXML()], extraProgram: true), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIReader.inspect(
            root.appendingPathComponent("legacy.nki")))
    }

    func testNKIRejectsMissingOrUnsafeAudioReferences() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try nki(document(zones: [
            zoneXML(sample: "../outside.wav", loop: false)
        ]), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source))
        _ = try nki(document(zones: [
            zoneXML(sample: "compressed.ncw", loop: false)
        ]), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source))
    }

    func testNKIRejectsDamagedZlibAndOutOfRangeLoop() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try nki(document(zones: [zoneXML()]), in: root)
        var damaged = try Data(contentsOf: source)
        damaged[damaged.count - 1] ^= 0xFF // break Adler32
        try damaged.write(to: source, options: .atomic)
        XCTAssertThrowsError(try StudioSamplerNKIReader.inspect(source))
        let samples = root.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(
            at: samples, withIntermediateDirectories: true)
        _ = try wav("tone.wav", in: samples)
        _ = try nki(document(zones: [
            zoneXML().replacingOccurrences(
                of: "value=\"68\"", with: "value=\"120\"")
        ]), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source))
    }

    func testNKIKeepsSameNamedSamplesInSeparateInstrumentSections() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let strings = root.appendingPathComponent("Samples/Strings", isDirectory: true)
        let brass = root.appendingPathComponent("Samples/Brass", isDirectory: true)
        try FileManager.default.createDirectory(
            at: strings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: brass, withIntermediateDirectories: true)
        let stringsURL = try wav("tone.wav", in: strings)
        let brassURL = try wav("tone.wav", in: brass)
        // Keep the files valid WAVs but give them distinct PCM recordings.
        var brassAudio = try Data(contentsOf: brassURL)
        brassAudio[60] ^= 0x42
        try brassAudio.write(to: brassURL, options: .atomic)
        _ = try wav("tone.wav", in: root) // Wrong basename-only match.
        let source = try nki(document(zones: [
            zoneXML(sample: "Samples/Strings/tone.wav",
                    low: 48, high: 59, loop: false),
            zoneXML(sample: "Samples/Brass/tone.wav",
                    low: 60, high: 72, loop: false)
        ]), in: root)

        let preview = try StudioSamplerNKIImporter.preview(source)
        XCTAssertEqual(preview.patch.zones.map(\.sampleURL),
                       [stringsURL, brassURL])
        let imported = try StudioSamplerNKIImporter.importInstrument(
            source, into: root.appendingPathComponent("managed"))
        XCTAssertEqual(Set(imported.patch.zones.map(\.filePath)).count, 2)
        XCTAssertEqual(try Data(contentsOf: imported.patch.zones[0].sampleURL),
                       Data(contentsOf: stringsURL))
        XCTAssertEqual(try Data(contentsOf: imported.patch.zones[1].sampleURL),
                       Data(contentsOf: brassURL))
        try StudioSamplerExternalFormatRoundTrip.assertPreserved(
            imported.patch, in: root, name: "NKI-DuplicateNames")
    }

    func testNKIExplicitFolderRelinkingUsesOriginalRelativePath() throws {
        let root = try temp()
        let external = try temp()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let localSamples = root.appendingPathComponent("Samples", isDirectory: true)
        let strings = external.appendingPathComponent("Strings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localSamples, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: strings, withIntermediateDirectories: true)
        _ = try wav("tone.wav", in: localSamples) // Wrong fallback.
        let expected = try wav("tone.wav", in: strings)
        let source = try nki(document(zones: [
            zoneXML(sample: "Strings/tone.wav", loop: false)
        ]), in: root)

        let preview = try StudioSamplerNKIImporter.preview(
            source, samplesRoot: external)
        XCTAssertEqual(preview.patch.zones[0].sampleURL, expected)
    }

    func testNKIRefusesAmbiguousBasenameRecovery() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = root.appendingPathComponent("Samples", isDirectory: true)
        try FileManager.default.createDirectory(
            at: samples, withIntermediateDirectories: true)
        _ = try wav("tone.wav", in: root)
        _ = try wav("tone.wav", in: samples)
        let source = try nki(document(zones: [
            zoneXML(sample: "OldArchive/tone.wav", loop: false)
        ]), in: root)
        XCTAssertThrowsError(try StudioSamplerNKIImporter.preview(source)) { error in
            guard case StudioSamplerNKIImporter.ImportError.ambiguousSample(let name)
                = error else {
                XCTFail("Expected an ambiguous-sample error, got \(error)")
                return
            }
            XCTAssertEqual(name, "tone.wav")
        }
    }
}
