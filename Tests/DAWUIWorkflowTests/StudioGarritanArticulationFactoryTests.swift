import XCTest
import DAWCore
@testable import DAWUI

final class StudioGarritanArticulationFactoryTests: XCTestCase {
    private let library = "Garritan Personal Orchestra 5"

    private func standard(_ patch: String) -> String {
        "\(library):Standard/Strings/KS Groups/\(patch)"
    }

    private func ready(_ result: StudioGarritanArticulationFactory.Resolution,
                       file: StaticString = #filePath, line: UInt = #line) -> StudioArticulationMap? {
        if case .ready(let map) = result { return map }
        XCTFail("Expected verified GPO5 factory map", file: file, line: line)
        return nil
    }

    func testStandardViolins1PatchMapsDocumentedKeyswitches() {
        let id = standard("Violins 1 KS")
        guard let map = ready(StudioGarritanArticulationFactory.resolve(programID: id)) else { return }
        XCTAssertEqual(map.articulations.count, 12)
        XCTAssertEqual(map.factoryProgramID, id)
        XCTAssertEqual(map.isFactoryDefault, true)

        func pitch(_ key: String) -> Int? {
            map.definition(for: key)?.actions.first?.number
        }
        // The GPO5 manual defines C4 = MIDI 60.
        XCTAssertEqual(pitch("sustain"), 36)       // C2
        XCTAssertEqual(pitch("pizzicato"), 41)     // F2
        XCTAssertEqual(pitch("staccato"), 46)      // A#2
        XCTAssertEqual(pitch("spiccato"), 45)      // A2
        XCTAssertEqual(pitch("sul-tasto"), 47)     // B2
    }

    func testStandardCello1UsesItsOwnLowerOctave() {
        guard let map = ready(StudioGarritanArticulationFactory.resolve(
            programID: standard("Cello 1 KS"))) else { return }
        XCTAssertEqual(map.definition(for: "pizzicato")?.actions.first?.number, 29) // F1
        XCTAssertEqual(map.definition(for: "sustain")?.actions.first?.number, 24) // C1
    }

    func testPiccoloC4IsMIDINote60() {
        guard let map = ready(StudioGarritanArticulationFactory.resolve(
            programID: "\(library):Standard/Woodwinds/Piccolo Solo KS")) else { return }
        XCTAssertEqual(map.articulations.first?.actions.first?.number, 60)
    }

    func testInstantOrchestraExplicitlyHasNoKeyswitchFactory() {
        let result = StudioGarritanArticulationFactory.resolve(
            programID: "Garritan Instant Orchestra:Standard/Strings/Full Strings MW")
        if case .instantOrchestra = result { } else { XCTFail("IO has no keyswitches") }
    }

    func testNotationPatchIsNeverMappedUsingStandardOctaves() {
        for path in ["Notation/Strings/n-Violins 1 KS",
                     "Standard/Strings/n-Violins 1 KS"] {
            let result = StudioGarritanArticulationFactory.resolve(
                programID: "\(library):\(path)")
            if case .needsReview = result { } else {
                XCTFail("Notation patch should require manual review")
            }
        }
    }

    func testDuplicateGPO5NamesRequireManualConfirmation() {
        for name in ["Violas KS", "Cellos KS", "Basses KS"] {
            let result = StudioGarritanArticulationFactory.resolve(
                programID: standard(name))
            if case .needsReview = result { } else {
                XCTFail("Ambiguous directory entry \(name) must not send guessed keyswitches")
            }
        }
    }

    func testPercussionPlaybackNotesAreNotMisreadAsKeyswitches() {
        let result = StudioGarritanArticulationFactory.resolve(
            programID: "\(library):Standard/Percussion/Percussion Accessories KS")
        if case .needsReview = result { } else {
            XCTFail("Playable percussion notes are not articulation triggers")
        }
    }

    func testPatchIdentityMustMatchWithoutGuessing() {
        for program in ["\(library):Standard/Strings/Violins 1",
                        "\(library):Woodwinds/Flute Solo KS",
                        "\(library):Standard/Strings/Unknown KS",
                        "Another Library:Standard/Strings/Violins 1 KS"] {
            let result = StudioGarritanArticulationFactory.resolve(programID: program)
            if case .ready = result {
                XCTFail("Unverified identity must not be played: \(program)")
            }
        }
    }

    func testFactoryDoesNotOverwriteUserMapIdentity() throws {
        var map = try XCTUnwrap(ready(
            StudioGarritanArticulationFactory.resolve(programID: standard("Violins 1 KS"))))
        map.articulations[0].actions[0].number = 33
        map.isFactoryDefault = false
        let roundTrip = try JSONDecoder().decode(
            StudioArticulationMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(roundTrip.articulations[0].actions[0].number, 33)
        XCTAssertEqual(roundTrip.isFactoryDefault, false)
        XCTAssertEqual(roundTrip.factoryProgramID, map.factoryProgramID)
    }

    func testGPO5NotationAndKeyboardSourceAreNotConflated() {
        let notes = StudioGarritanArticulationFactory.instantOrchestraPerformanceNotes
        XCTAssertTrue(notes.contains { $0.contains("no keyswitch") || $0.contains("No keyswitch") })
        XCTAssertTrue(notes.contains { $0.contains("CC104") })
        XCTAssertTrue(notes.contains { $0.contains("CC30") })
    }
}
