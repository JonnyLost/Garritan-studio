import XCTest
@testable import DAWCore

final class GarritanPluginDiscoveryTests: XCTestCase {
    func testEmptyDirectoryHasNoCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(GarritanPluginDiscovery.discover(in: [root]).isEmpty)
    }

    func testFindsARIABundleWithoutLoadingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("ARIA Player.vst3", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "CFBundleName": "ARIA Player",
            "CFBundleIdentifier": "example.aria.player"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let results = GarritanPluginDiscovery.discover(in: [root, root])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.format, .vst3)
        XCTAssertEqual(results.first?.bundleIdentifier, "example.aria.player")
    }

    func testIgnoresUnrelatedPlugins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Unrelated.component", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(GarritanPluginDiscovery.discover(in: [root]).isEmpty)
    }
}
