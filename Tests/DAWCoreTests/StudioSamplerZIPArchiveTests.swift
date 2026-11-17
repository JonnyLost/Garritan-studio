import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerZIPArchiveTests: XCTestCase {
    private func append16(_ value: Int, to bytes: inout Data) {
        bytes.append(UInt8(value & 255))
        bytes.append(UInt8((value >> 8) & 255))
    }
    private func append32(_ value: Int, to bytes: inout Data) {
        append16(value & 65535, to: &bytes)
        append16((value >> 16) & 65535, to: &bytes)
    }
    private func archive(_ names: [String]) throws -> URL {
        var central = Data()
        for name in names {
            let bytes = Data(name.utf8)
            append32(0x02014b50, to: &central)
            append16(20, to: &central)
            append16(20, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(0, to: &central)
            append32(0, to: &central)
            append32(0, to: &central)
            append16(bytes.count, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(0, to: &central)
            append32(0, to: &central)
            central.append(bytes)
        }
        var result = central
        append32(0x06054b50, to: &result)
        append16(0, to: &result)
        append16(0, to: &result)
        append16(names.count, to: &result)
        append16(names.count, to: &result)
        append32(central.count, to: &result)
        append32(0, to: &result)
        append16(0, to: &result)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        try result.write(to: url)
        return url
    }

    func testDiscoversInstrumentAndSampleEntries() throws {
        let url = try archive(["Strings/Violin.nki", "Strings/Violin.wav"])
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try StudioSamplerZIPArchive.inspect(url)
        XCTAssertEqual(report.candidates.map(\.relativePath),
                       ["Strings/Violin.nki", "Strings/Violin.wav"])
    }

    func testRejectsTraversalAndCaseInsensitiveCollisions() throws {
        for paths in [["../outside.wav"], ["/absolute.sfz"],
                      ["safe\\evil.wav"], ["A.wav", "a.WAV"]] {
            let url = try archive(paths)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(try StudioSamplerZIPArchive.inspect(url))
        }
    }

    func testEntryLimitIsEnforced() throws {
        let url = try archive(["a.wav", "b.wav"])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try StudioSamplerZIPArchive.inspect(url, maxEntries: 1))
    }
}
