import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerImportDiscoveryTests: XCTestCase {
    func testFormatClassificationDoesNotPromiseUnsupportedConversion() {
        XCTAssertEqual(StudioSamplerImportDiscovery.classify(
            URL(fileURLWithPath: "/samples/violin.NKI")).0, .kontakt)
        XCTAssertEqual(StudioSamplerImportDiscovery.classify(
            URL(fileURLWithPath: "/samples/multi.nkm")).1, .requiresAdapter)
        XCTAssertEqual(StudioSamplerImportDiscovery.classify(
            URL(fileURLWithPath: "/samples/library.zip")).1, .archiveInspection)
        XCTAssertEqual(StudioSamplerImportDiscovery.classify(
            URL(fileURLWithPath: "/samples/note.wav")).1, .sampleMapping)
    }

    func testFolderDiscoverySkipsLinksAndFindsNestedMappings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Strings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("Violin.sfz"))
        try Data().write(to: nested.appendingPathComponent("Violin.wav"))
        try Data().write(to: nested.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("shortcut"),
            withDestinationURL: nested)
        let result = try StudioSamplerImportDiscovery.scanDirectory(root)
        XCTAssertEqual(result.candidates.map(\.relativePath),
                       ["Strings/Violin.sfz", "Strings/Violin.wav"])
        XCTAssertEqual(result.skippedSymbolicLinks, 1)
        XCTAssertFalse(result.truncated)
    }

    func testScanEntryLimitReportsIncompleteInventory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        for index in 0..<5 {
            try Data().write(to: root.appendingPathComponent("sample\(index).wav"))
        }
        let result = try StudioSamplerImportDiscovery.scanDirectory(
            root, maxEntries: 2)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.truncated)
    }
}
