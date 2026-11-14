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

    func testStandardUniqueSoloViolin1PatchMapsDocumentedKeyswitches() {
        let id = standard("Violin 1 KS")
        guard let map = ready(StudioGarritanArticulationFactory.resolve(programID: id)) else { return }
        XCTAssertEqual(map.articulations.count, 9)
        XCTAssertEqual(map.factoryProgramID, id)
        XCTAssertEqual(map.isFactoryDefault, true)

        func pitch(_ key: String) -> Int? {
            map.definition(for: key)?.actions.first?.number
        }
        // The GPO5 manual defines C4 = MIDI 60.
        XCTAssertEqual(pitch("sustain"), 36)       // C2
        XCTAssertEqual(pitch("pizzicato"), 41)     // F2
        XCTAssertEqual(pitch("spiccato"), 43)      // G2
        XCTAssertEqual(pitch("staccato"), 44)      // G#2
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

    func testCollidingNamesWithoutExplicitBankContextRemainUnarmed() {
        for name in ["Violins 1 KS", "Violins 2 KS",
                     "Violas KS", "Cellos KS", "Basses KS"] {
            let result = StudioGarritanArticulationFactory.resolve(
                programID: "\(library):Standard/Strings/\(name)")
            if case .needsReview = result { } else {
                XCTFail("Context-free \(name) must not send guessed keyswitches")
            }
        }
    }

    func testGPO5KeyswitchGroupsUseDifferentArticulationMeanings() {
        let group = tryReady("\(library):Standard/Strings/KS Groups/Violins 1 KS")
        let section = tryReady("\(library):Standard/Strings/Section Strings/Violins 1 KS")
        XCTAssertEqual(group?.articulations.count, 12)
        XCTAssertEqual(section?.articulations.count, 12)
        XCTAssertEqual(group?.articulations[0].name, "Sustains")
        XCTAssertEqual(section?.articulations[0].name,
                       "sus+short (legato with sustain pedal)")
        XCTAssertEqual(group?.articulations.first { $0.name == "Marcato" }?
                       .actions.first?.number, 39) // D#2
        XCTAssertFalse(section?.articulations.contains { $0.name == "Marcato" } ?? true)
    }

    func testGPO5KSGroupViolasCellosAndBassesArePathSpecific() {
        let names: [(String, Int, Int)] = [
            ("Violas KS", 9, 36),
            ("Cellos KS", 9, 24),
            ("Basses KS", 8, 12)
        ]
        for (name, count, initial) in names {
            let map = tryReady("\(library):Standard/Strings/09 KS Groups/\(name)")
            XCTAssertEqual(map?.articulations.count, count)
            XCTAssertEqual(map?.articulations.first?.actions.first?.number, initial)
        }
    }

    func testChoirBassesAreVowelsNotStringBowing() {
        let id = "\(library):Standard/Choir/Basses KS"
        let choir = tryReady(id)
        XCTAssertEqual(choir?.articulations.map(\.name), ["Aahs", "Ohs"])
        XCTAssertEqual(choir?.articulations.map { $0.actions.first?.number }, [24, 26])
        let unscoped = StudioGarritanArticulationFactory.resolve(
            programID: "\(library):Standard/Other/Basses KS")
        if case .needsReview = unscoped { } else {
            XCTFail("A choir/string collision cannot use a generic basename")
        }
    }

    func testPercussionUsesSwitchPitchesNotPlayableDrumRanges() {
        let cases: [(String, [Int])] = [
            ("Percussion Accessories KS", [48, 50]),
            ("Snares KS", [48, 50]),
            ("Timpani 1 KS", [24, 26]),
            ("Timpani 2 KS", [24, 26]),
            ("Timpani 3 KS", [24, 26, 28])
        ]
        for (name, pitches) in cases {
            let map = tryReady("\(library):Standard/Percussion/\(name)")
            XCTAssertEqual(map?.articulations.compactMap { $0.actions.first?.number },
                           pitches, "Playable drum notes must never become articulation keyswitches")
        }
        if case .needsReview = StudioGarritanArticulationFactory.resolve(
            programID: "\(library):Standard/Other/Snares KS") { } else {
            XCTFail("Percussion folder must be confirmed")
        }
    }

    func testNotationTemplateProvidesLabelsButNoUnverifiedMIDI() {
        let program = "\(library):Notation/Strings/KS Groups/n-Violins 1 KS"
        if case .needsReview = StudioGarritanArticulationFactory.resolve(
            programID: program) { } else {
            XCTFail("Notation cannot be armed with Standard octaves")
        }
        guard let map = StudioGarritanArticulationFactory.notationTemplate(
            programID: program) else {
            XCTFail("Expected a user-calibratable Notation reference")
            return
        }
        XCTAssertEqual(map.articulations.count, 12)
        XCTAssertEqual(map.articulations.first?.name, "Sustains")
        XCTAssertTrue(map.articulations.allSatisfy { $0.actions.isEmpty })
        XCTAssertEqual(map.factoryProgramID, program)
        XCTAssertEqual(map.isFactoryDefault, false)
        XCTAssertNil(StudioGarritanArticulationFactory.notationTemplate(
            programID: "\(library):Standard/Strings/KS Groups/Violins 1 KS"))
    }

    private func tryReady(_ id: String,
                          file: StaticString = #filePath, line: UInt = #line)
        -> StudioArticulationMap? {
        if case .ready(let map) =
            StudioGarritanArticulationFactory.resolve(programID: id) {
            return map
        }
        XCTFail("Expected verified GPO5 Standard map for \(id)", file: file, line: line)
        return nil
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
            StudioGarritanArticulationFactory.resolve(programID: standard("Violin 1 KS"))))
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
