import Foundation
import XCTest
@testable import DAWCore

final class StudioSamplerSF2ReaderTests: XCTestCase {
    func testRejectsNonSoundFont() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-\(UUID().uuidString).sf2")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a soundfont".utf8).write(to: url)
        XCTAssertThrowsError(try StudioSamplerSF2Reader.inspect(url))
    }

    func testRejectsTruncatedRIFF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("truncated-\(UUID().uuidString).sf2")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([82,73,70,70, 100,0,0,0, 115,102,98,107]).write(to: url)
        XCTAssertThrowsError(try StudioSamplerSF2Reader.inspect(url))
    }
}
