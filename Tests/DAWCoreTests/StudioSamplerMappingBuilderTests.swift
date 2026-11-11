import XCTest
@testable import DAWCore

final class StudioSamplerMappingBuilderTests: XCTestCase {
    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testPitchAndVelocityFilenameParsing() {
        XCTAssertEqual(StudioSamplerMappingBuilder.noteNumber(in: file("Violin_C4_pp.wav")), 60)
        XCTAssertEqual(StudioSamplerMappingBuilder.noteNumber(in: file("Strings_C#5_ff.aif")), 73)
        XCTAssertEqual(StudioSamplerMappingBuilder.noteNumber(in: file("Cello_Bb3_mf.wav")), 58)
        XCTAssertNil(StudioSamplerMappingBuilder.noteNumber(in: file("sustain.wav")))
        XCTAssertEqual(StudioSamplerMappingBuilder.velocityHint(in: file("Strings_C4_pp.wav")), 32)
        XCTAssertEqual(StudioSamplerMappingBuilder.velocityHint(in: file("Strings_C4_vel105.wav")), 105)
        XCTAssertNil(StudioSamplerMappingBuilder.velocityHint(in: file("Strings_C4.wav")))
    }

    func testTwoNotesAndThreeDynamicLayersProduceNonOverlappingRanges() throws {
        let sources = [
            file("Violin_C4_ff.wav"), file("Violin_G4_pp.wav"),
            file("Violin_C4_pp.wav"), file("Violin_C4_mf.wav")
        ]
        let patch = try StudioSamplerMappingBuilder.makePatch(urls: sources)
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 4)
        let c = patch.zones.filter { $0.rootNote == 60 }
        let g = patch.zones.filter { $0.rootNote == 67 }
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(c.map(\.lowestVelocity), [1, 43, 85])
        XCTAssertEqual(c.map(\.highestVelocity), [42, 84, 127])
        XCTAssertEqual(c.map(\.lowestNote), [0, 0, 0])
        XCTAssertEqual(c.map(\.highestNote), [63, 63, 63])
        XCTAssertEqual(g[0].lowestNote, 64)
        XCTAssertEqual(g[0].highestNote, 127)
        XCTAssertEqual(g[0].lowestVelocity, 1)
        XCTAssertEqual(g[0].highestVelocity, 127)
    }

    func testUnknownNamesAssignDeterministicNeighboringRoots() throws {
        let patch = try StudioSamplerMappingBuilder.makePatch(
            urls: [file("Zebra.wav"), file("Alpha.wav")]
        )
        XCTAssertEqual(patch.zones.map(\.rootNote), [60, 61])
        XCTAssertEqual(patch.zones.map(\.lowestNote), [0, 61])
        XCTAssertEqual(patch.zones.map(\.highestNote), [60, 127])
    }

    func testOversizedImportRejected() {
        XCTAssertThrowsError(try StudioSamplerMappingBuilder.makePatch(urls: []))
        XCTAssertThrowsError(
            try StudioSamplerMappingBuilder.makePatch(
                urls: (0..<129).map { file("sample-\($0).wav") }
            )
        )
    }

    func testImportedAudioIsCopiedToStableStorage() throws {
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-import-\(UUID().uuidString).wav")
        let contents = Data([0x52, 0x49, 0x46, 0x46])
        try contents.write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let imported = try StudioSamplerSampleLibrary.importFiles([original])
        XCTAssertEqual(imported.count, 1)
        defer { try? FileManager.default.removeItem(at: imported[0]) }
        XCTAssertNotEqual(imported[0], original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: imported[0]), contents)
        XCTAssertEqual(try StudioSamplerSampleLibrary.importFiles(imported), imported)
    }
}
