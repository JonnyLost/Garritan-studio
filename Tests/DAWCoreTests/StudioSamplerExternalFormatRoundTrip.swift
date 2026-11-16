import Foundation
import XCTest
@testable import DAWCore

/// Shared, on-disk acceptance test for all external sampler converters.
/// Both package creation and restoration use the same production APIs as
/// Studio's Instrument Library. Only synthetic/copyright-free fixtures are
/// exercised in the repository's automated suite.
enum StudioSamplerExternalFormatRoundTrip {
    static func assertPreserved(_ imported: StudioSamplerPatch,
                                in directory: URL,
                                name: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        XCTAssertTrue(imported.isValid, file: file, line: line)
        let package = directory.appendingPathComponent(
            "Verified-\(name).studioinstrument", isDirectory: true)
        let output = directory.appendingPathComponent(
            "Reopened-\(name)", isDirectory: true)
        let sources = imported.zones.map { URL(fileURLWithPath: $0.filePath) }
        var originals: [Data] = []
        for url in sources {
            originals.append(try Data(contentsOf: url))
        }

        try StudioSamplerInstrumentPackage.export(
            imported, metadata: StudioSamplerInstrumentPackage.Metadata(
                name: "Verified \(name)", category: "Imported"), to: package)
        let (reopened, metadata) = try StudioSamplerInstrumentPackage.load(
            package, into: output)
        XCTAssertEqual(metadata.name, "Verified \(name)", file: file, line: line)
        XCTAssertTrue(reopened.isValid, file: file, line: line)
        XCTAssertEqual(reopened.zones.count, imported.zones.count,
                       file: file, line: line)

        // A portable package must preserve the complete instrument's tuning,
        // layers, loops, round-robin, release and articulation metadata;
        // only paths and ownership metadata may change.
        var expected = imported
        var actual = reopened
        for index in imported.zones.indices {
            XCTAssertNotEqual(sources[index].path, reopened.zones[index].filePath,
                              file: file, line: line)
            let restored = URL(fileURLWithPath: reopened.zones[index].filePath)
            XCTAssertEqual(try Data(contentsOf: restored), originals[index],
                           file: file, line: line)
            expected.zones[index].filePath = "SOURCE"
            expected.zones[index].managedFileName = nil
            actual.zones[index].filePath = "SOURCE"
            actual.zones[index].managedFileName = nil
        }
        XCTAssertEqual(actual, expected,
                       "Sampler performance mapping changed during package export/load",
                       file: file, line: line)
        XCTAssertEqual(
            Set(reopened.zones.map(\.filePath)).count,
            Set(imported.zones.map(\.filePath)).count,
            "Package must not duplicate or merge distinct recordings",
            file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: output, includingPropertiesForKeys: nil).count,
            Set(reopened.zones.map(\.filePath)).count,
            file: file, line: line)
    }
}
