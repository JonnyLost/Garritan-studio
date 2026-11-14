import XCTest
@testable import DAWCore

final class StudioExportPlanTests: XCTestCase {
    private func project() -> Project {
        var project = Project(name: "Suite 1", sampleRate: 44_100)
        project.tempo = Tempo(bpm: 120)
        var strings = Track(name: "Violins I", type: .instrument)
        strings.garritanProgramID = "GPO5:Standard/Strings/Violins/Section"
        strings.clips = [Clip(
            name: "Phrase",
            timeRange: TimeRange(
                start: TimePosition(seconds: 0),
                duration: TimePosition(seconds: 2)
            ),
            content: .empty
        )]
        var brass = Track(name: "Horn 1", type: .instrument)
        brass.garritanProgramID = "GPO5:Standard/Brass/Horns"
        var synth = Track(name: "Granular Texture", type: .instrument)
        synth.studioSynthEnabled = true
        var audio = Track(name: "Dialogue", type: .audio)
        audio.isMuted = false
        project.tracks = [strings, brass, synth, audio]
        return project
    }

    func testStereoMonoAndFullMixSoloIsolation() throws {
        var p = project()
        let stereo = try StudioExportPlan.makePasses(
            project: p, settings: StudioExportSettings(mode: .stereoMix)
        )
        XCTAssertEqual(stereo.count, 1)
        XCTAssertEqual(stereo[0].channelCount, 2)
        XCTAssertEqual(stereo[0].trackIDs.count, 4)

        p.tracks[1].isSolo = true
        p.tracks[3].isMuted = true
        let mono = try StudioExportPlan.makePasses(
            project: p, settings: StudioExportSettings(mode: .monoMix)
        )
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(mono[0].channelCount, 1)
        XCTAssertEqual(mono[0].trackIDs, Set([p.tracks[1].id]))
    }

    func testIndividualExportsUseOriginalTrackOrdering() throws {
        let p = project()
        let settings = StudioExportSettings(
            mode: .individualTracks,
            selectedTrackIDs: [p.tracks[2].id, p.tracks[0].id]
        )
        let passes = try StudioExportPlan.makePasses(project: p, settings: settings)
        XCTAssertEqual(passes.map(\.name), ["Violins I", "Granular Texture"])
        XCTAssertEqual(passes[0].trackIDs, Set([p.tracks[0].id]))
        XCTAssertEqual(passes[1].trackIDs, Set([p.tracks[2].id]))
        XCTAssertEqual(passes.map(\.channelCount), [2, 2])
    }

    func testFamilyGroupsAreDerivedFromRealInstrumentIdentity() {
        let p = project()
        let families = StudioExportPlan.groupsByFamily(p)
        XCTAssertEqual(Set(families.map(\.name)),
                       Set(["Strings", "Brass", "Synth", "Audio"]))
        XCTAssertEqual(families.first { $0.name == "Synth" }?.trackIDs,
                       [p.tracks[2].id])
    }

    func testCustomStemAllowsTrackOverlapButNeverIncludesUnselectedSources() throws {
        let p = project()
        let stems = [
            StudioExportStem(name: "Strings + Synth",
                             trackIDs: [p.tracks[0].id, p.tracks[2].id]),
            StudioExportStem(name: "Solo Synth", trackIDs: [p.tracks[2].id])
        ]
        let passes = try StudioExportPlan.makePasses(
            project: p,
            settings: StudioExportSettings(mode: .customStems, stems: stems)
        )
        XCTAssertEqual(passes.count, 2)
        XCTAssertEqual(passes[0].trackIDs.count, 2)
        XCTAssertEqual(passes[1].trackIDs, Set([p.tracks[2].id]))
        let isolated = StudioExportPlan.isolatedProject(p, for: passes[0])
        XCTAssertEqual(Set(isolated.tracks.map(\.id)),
                       Set([p.tracks[0].id, p.tracks[2].id]))
        XCTAssertEqual(p.tracks.count, 4, "Never mutate the source session")
    }

    func testRejectsAmbiguousStemFilenamesAndPathTraversal() {
        let p = project()
        let stems = [
            StudioExportStem(name: "STRINGS", trackIDs: [p.tracks[0].id]),
            StudioExportStem(name: "strings", trackIDs: [p.tracks[1].id])
        ]
        XCTAssertThrowsError(try StudioExportPlan.makePasses(
            project: p,
            settings: StudioExportSettings(mode: .customStems, stems: stems)
        ))
        XCTAssertEqual(StudioExportPlan.safeFilename("../Bad/Name"), ".-Bad-Name")
        XCTAssertFalse(StudioExportPlan.safeFilename(" \n ").isEmpty)
    }

    func testRejectsMissingTracksAndEmptyGroups() {
        let p = project()
        XCTAssertThrowsError(try StudioExportPlan.makePasses(
            project: p,
            settings: StudioExportSettings(
                mode: .customStems,
                stems: [StudioExportStem(name: "Empty", trackIDs: [])]
            )
        ))
        XCTAssertThrowsError(try StudioExportPlan.makePasses(
            project: p,
            settings: StudioExportSettings(
                mode: .customStems,
                stems: [StudioExportStem(name: "Missing", trackIDs: [TrackID()])]
            )
        ))
    }

    func testValidatesConstantTempoRenderExtentAndTail() throws {
        var p = project()
        XCTAssertEqual(try StudioExportPlan.renderSeconds(
            project: p, tailSeconds: 3
        ), 5, accuracy: 0.001)
        p.tempoChanges = [TempoChange(
            beatPosition: 1, tempo: Tempo(bpm: 84)
        )]
        XCTAssertThrowsError(try StudioExportPlan.renderSeconds(
            project: p, tailSeconds: 3
        ))
        p.tempoChanges = []
        p.tracks[0].clips[0].isLooped = true
        XCTAssertThrowsError(try StudioExportPlan.renderSeconds(
            project: p, tailSeconds: 3
        ))
    }

    func testRejectsUnsupportedPCMBitDepth() {
        let p = project()
        XCTAssertThrowsError(try StudioExportPlan.makePasses(
            project: p,
            settings: StudioExportSettings(mode: .stereoMix, bitDepth: 12)
        ))
    }
}
