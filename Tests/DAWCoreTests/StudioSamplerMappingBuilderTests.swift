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

    func testRoundRobinImportsShareVelocityBandsAndSeparateReleaseSamples() throws {
        let urls = [
            file("Violin_C4_pp_rr1.wav"), file("Violin_C4_pp_rr2.wav"),
            file("Violin_C4_ff_rr1.wav"), file("Violin_C4_ff_rr2.wav"),
            file("Violin_C4_release_rr1.wav"), file("Violin_C4_release_rr2.wav")
        ]
        let patch = try StudioSamplerMappingBuilder.makePatch(urls: urls)
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 6)
        let attacks = patch.zones.filter { $0.isReleaseTrigger != true }
        let releases = patch.zones.filter { $0.isReleaseTrigger == true }
        XCTAssertEqual(attacks.count, 4)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(attacks.map(\.lowestVelocity), [1, 1, 64, 64])
        XCTAssertEqual(attacks.map(\.highestVelocity), [63, 63, 127, 127])
        XCTAssertEqual(attacks.map(\.roundRobinIndex), [0, 1, 0, 1])
        XCTAssertEqual(releases.map(\.lowestVelocity), [1, 1])
        XCTAssertEqual(releases.map(\.highestVelocity), [127, 127])
        XCTAssertEqual(releases.map(\.roundRobinIndex), [0, 1])
    }

    func testRoundRobinFilenameHintsDoNotChangeOrdinaryVelocityMapping() {
        XCTAssertEqual(StudioSamplerMappingBuilder.roundRobinHint(in: file("C4_rr1.wav")), 0)
        XCTAssertEqual(StudioSamplerMappingBuilder.roundRobinHint(in: file("C4_take8.wav")), 7)
        XCTAssertNil(StudioSamplerMappingBuilder.roundRobinHint(in: file("C4_rr9.wav")))
        XCTAssertNil(StudioSamplerMappingBuilder.roundRobinHint(in: file("C4.wav")))
        XCTAssertTrue(StudioSamplerMappingBuilder.releaseHint(in: file("Violin_C4_rel_rr2.wav")))
        XCTAssertFalse(StudioSamplerMappingBuilder.releaseHint(in: file("Violin_C4_sus_rr2.wav")))
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
    func testArticulationsHaveIndependentKeyMapsAndKeyswitches() throws {
        let patch = try StudioSamplerMappingBuilder.makePatch(urls: [
            file("Violin_C4_sustain_pp.wav"), file("Violin_G4_sustain_ff.wav"),
            file("Violin_C4_pizz_rr1.wav"), file("Violin_C4_pizz_rr2.wav"),
            file("Violin_D4_stacc_vel100.wav")
        ])
        XCTAssertTrue(patch.isValid)
        let pizz = try XCTUnwrap(patch.articulations?.first(where: { $0.name == "Pizzicato" }))
        let stacc = try XCTUnwrap(patch.articulations?.first(where: { $0.name == "Staccato" }))
        XCTAssertNotEqual(pizz.id, stacc.id)
        let pizzZones = patch.zones.filter { $0.articulationID == pizz.id }
        XCTAssertEqual(pizzZones.count, 2)
        XCTAssertEqual(pizzZones.map(\.lowestNote), [0, 0])
        XCTAssertEqual(pizzZones.map(\.highestNote), [127, 127])
        XCTAssertEqual(pizzZones.map(\.roundRobinIndex), [0, 1])
        XCTAssertEqual(patch.zones.filter { ($0.articulationID ?? 0) == 0 }.count, 2)
        XCTAssertEqual(patch.defaultKeyswitchNote, 23)
        XCTAssertEqual(StudioSamplerMappingBuilder.noteNumber(in: file("Cello_midi36_pp.wav")), 36)
        XCTAssertEqual(StudioSamplerMappingBuilder.noteNumber(in: file("Cello_note48_ff.wav")), 48)
        XCTAssertEqual(StudioSamplerMappingBuilder.articulationHint(
            in: file("Cello_D3_sustain.wav")), nil)
    }

    func testAppendReusesArticulationsAndPreservesExistingEdits() throws {
        let original = try StudioSamplerMappingBuilder.makePatch(urls: [
            file("Violin_C4_pizz.wav")
        ])
        var edited = original
        edited.zones[0].trimStartFrame = 24
        edited.zones[0].trimEndFrame = 400
        let added = try StudioSamplerMappingBuilder.makePatch(urls: [
            file("Violin_G4_pizz.wav"), file("Violin_D4_stacc.wav")
        ])
        let combined = try StudioSamplerMappingBuilder.append(added, to: edited)
        XCTAssertTrue(combined.isValid)
        XCTAssertEqual(combined.zones.count, 3)
        XCTAssertEqual(combined.zones[0].trimStartFrame, 24)
        XCTAssertEqual(combined.articulations?.count, 2)
        XCTAssertEqual(combined.zones[0].articulationID, combined.zones[1].articulationID)
        XCTAssertNotEqual(combined.zones[1].articulationID, combined.zones[2].articulationID)
    }

    func testOrchestralMicAndIntervalFilenamesStayDistinctFromSustains() throws {
        let patch = try StudioSamplerMappingBuilder.makePatch(urls: [
            file("Violin_C4_close_mf.wav"),
            file("Violin_C4_room_mf.wav"),
            file("Violin_D4_close_mf.wav"),
            file("Violin_D4_room_mf.wav"),
            file("Violin_fromC4_toD4_legato_close_mf.wav"),
            file("Violin_fromC4_toD4_legato_room_mf.wav")
        ])
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 6)
        XCTAssertTrue(patch.legatoEnabled == true)
        XCTAssertEqual(patch.legatoCrossfadeMilliseconds, 40)
        XCTAssertEqual(patch.microphones?.map(\.id), [0, 2])
        let transitions = patch.zones.filter { $0.legatoFromNote != nil }
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions.map(\.legatoFromNote), [60, 60])
        XCTAssertEqual(transitions.map(\.rootNote), [62, 62])
        XCTAssertTrue(transitions.allSatisfy {
            $0.lowestNote == 62 && $0.highestNote == 62
        })
        XCTAssertEqual(Set(transitions.map { $0.microphoneID ?? 0 }), Set([0, 2]))
        XCTAssertEqual(patch.zones.filter { $0.legatoFromNote == nil }.count, 4)
        XCTAssertNil(patch.articulations)
        XCTAssertEqual(StudioSamplerMappingBuilder.microphoneHint(in: file("flute_room.wav")), 2)
        XCTAssertEqual(StudioSamplerMappingBuilder.legatoIntervalHint(
            in: file("Violin_fromC4_toD4_legato.wav"))?.to, 62)
        XCTAssertNil(StudioSamplerMappingBuilder.legatoIntervalHint(
            in: file("Violin_C4_legato.wav")))
    }

    func testAppendPreservesMicLevelsAndAddsNewPosition() throws {
        let existing = try StudioSamplerMappingBuilder.makePatch(
            urls: [file("Violin_C4_room.wav")]
        )
        var modified = existing
        modified.microphones?[0].gain = 0.2
        let incoming = try StudioSamplerMappingBuilder.makePatch(
            urls: [file("Violin_C4_tree.wav")]
        )
        let merged = try StudioSamplerMappingBuilder.append(incoming, to: modified)
        XCTAssertTrue(merged.isValid)
        XCTAssertEqual(merged.zones.count, 2)
        XCTAssertEqual(merged.microphones?.count, 2)
        XCTAssertEqual(merged.microphones?.first(where: { $0.id == 2 })?.gain, 0.2)
        XCTAssertEqual(Set(merged.zones.map { $0.microphoneID ?? 0 }), Set([1, 2]))
    }

}
