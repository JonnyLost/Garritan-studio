import Foundation
import XCTest
@testable import DAWCore

final class StudioSoundDescriptionInterpreterTests: XCTestCase {
    private func interpret(
        _ text: String, mode: StudioSoundDesignMode = .create
    ) throws -> StudioSoundDescriptionIntent {
        try StudioSoundDescriptionInterpreter.interpret(text, mode: mode)
    }

    private func require(
        _ intent: StudioSoundDescriptionIntent,
        _ quality: StudioSoundQuality,
        _ action: StudioSoundInstructionAction
    ) throws -> StudioSoundQualityInstruction {
        let instruction = try XCTUnwrap(intent.instruction(for: quality))
        XCTAssertEqual(instruction.action, action, quality.rawValue)
        XCTAssertTrue((0...1).contains(instruction.amount), quality.rawValue)
        return instruction
    }

    func testCinematicPadDescriptionRecognizesIndependentSoundCharacteristics() throws {
        let prompt = """
        A dark, cinematic string-like pad with a slow attack, warm low
        frequencies, and shimmering metallic harmonics that gradually emerge.
        Something mysterious and spacious.
        """
        let intent = try interpret(prompt)
        XCTAssertEqual(intent.mode, .create)
        XCTAssertEqual(intent.originalText, prompt)
        XCTAssertEqual(intent.role, .pad)
        XCTAssertTrue(intent.families.contains(.strings))
        XCTAssertTrue(intent.engineHints.isEmpty, "Only explicit engine mentions count")
        XCTAssertLessThan(try require(intent, .brightness, .set).amount, 0.5)
        XCTAssertGreaterThan(try require(intent, .warmth, .set).amount, 0.5)
        XCTAssertGreaterThan(try require(intent, .attackTime, .set).amount, 0.5)
        XCTAssertGreaterThan(try require(intent, .lowEnd, .set).amount, 0.5)
        XCTAssertGreaterThan(try require(intent, .metallicCharacter, .set).amount, 0.5)
        XCTAssertGreaterThan(try require(intent, .harmonicComplexity, .set).amount, 0.5)
        XCTAssertGreaterThan(try require(intent, .spaciousness, .set).amount, 0.5)
        XCTAssertTrue(intent.hasRecognizedIntent)
    }

    func testRefinementReturnsRelativeChangeInsteadOfOverwritingPatch() throws {
        let intent = try interpret(
            "Make it less metallic and a little warmer, with slower attack and more movement.",
            mode: .refine)
        XCTAssertEqual(try require(intent, .metallicCharacter, .decrease).amount, 0.26)
        XCTAssertEqual(try require(intent, .warmth, .increase).amount, 0.12)
        XCTAssertEqual(try require(intent, .attackTime, .increase).amount, 0.26)
        XCTAssertEqual(try require(intent, .movement, .increase).amount, 0.26)
        XCTAssertNil(intent.role)
    }

    func testExplicitComparativesRemainRelativeEvenWhenCreating() throws {
        let intent = try interpret("Less bright but much more movement.")
        XCTAssertEqual(try require(intent, .brightness, .decrease).amount, 0.26)
        XCTAssertEqual(try require(intent, .movement, .increase).amount, 0.43)
    }

    func testNegationAndExclusionsAreNotPositiveFeatures() throws {
        let intent = try interpret(
            "A pad that's not too bright, without metallic bells, no drums and no reverb.")
        XCTAssertEqual(intent.role, .pad)
        XCTAssertLessThan(try require(intent, .brightness, .set).amount, 0.5)
        XCTAssertLessThan(try require(intent, .metallicCharacter, .set).amount, 0.5)
        XCTAssertLessThan(try require(intent, .spaciousness, .set).amount, 0.5)
        XCTAssertTrue(intent.excludedFamilies.contains(.bells))
        XCTAssertTrue(intent.excludedFamilies.contains(.percussion))
        XCTAssertFalse(intent.families.contains(.bells))
        XCTAssertFalse(intent.families.contains(.percussion))
    }

    func testExplicitEngineHintsAreTypedAndDoNotGuessEngines() throws {
        let intent = try interpret(
            "An analog and FM pad, with wavetable shimmer; avoid granular grains.")
        XCTAssertEqual(intent.role, .pad)
        XCTAssertEqual(intent.engineHints, [.analog, .fm, .wavetable])
        XCTAssertEqual(intent.excludedEngines, [.granular])
        XCTAssertFalse(intent.engineHints.contains(.granular))
        let ordinary = try interpret("A warm string-like pad with metallic harmonics.")
        XCTAssertTrue(ordinary.engineHints.isEmpty)
    }

    func testRolePrefersMostRecentlyNamedInstrumentNotBassModifier() throws {
        let intent = try interpret("A bass-heavy pad with slow attack.")
        XCTAssertEqual(intent.role, .pad)
        XCTAssertNotNil(intent.instruction(for: .attackTime))
    }

    func testMatchingUsesWholeWordsInsteadOfSubstrings() throws {
        let unknown = try interpret("The farmer passes a fashionable melody.")
        XCTAssertFalse(unknown.hasRecognizedIntent)
        XCTAssertTrue(unknown.instructions.isEmpty)
        XCTAssertNil(unknown.role)
    }

    func testLastMentionWinsAndConjunctionSeparatesComparatives() throws {
        let intent = try interpret(
            "A bright lead, but actually make it darker and more metallic.",
            mode: .refine)
        XCTAssertEqual(intent.role, .lead)
        XCTAssertEqual(try require(intent, .brightness, .decrease).evidence, "darker")
        XCTAssertEqual(try require(intent, .metallicCharacter, .increase).evidence,
                       "metallic")
    }

    func testMalformedAndOversizedRequestsFailCleanly() throws {
        XCTAssertThrowsError(try interpret("   ")) { error in
            XCTAssertEqual(error as? StudioSoundDescriptionError, .emptyDescription)
        }
        XCTAssertThrowsError(try interpret(String(repeating: "a", count: 2_001))) {
            error in
            XCTAssertEqual(error as? StudioSoundDescriptionError, .descriptionTooLong)
        }
        let unknown = try interpret("Please make an unusual instrument.")
        XCTAssertFalse(unknown.hasRecognizedIntent)
    }

    func testPunctuationSeparatesModificationScopes() throws {
        let intent = try interpret("A slightly warm pad, with a slow attack.")
        XCTAssertEqual(try require(intent, .warmth, .set).amount, 0.62)
        XCTAssertEqual(try require(intent, .attackTime, .set).amount, 0.78)

        let excluded = try interpret("No bells, a bright pad.")
        XCTAssertEqual(excluded.role, .pad)
        XCTAssertEqual(excluded.excludedFamilies, [.bells])
        XCTAssertGreaterThan(try require(excluded, .brightness, .set).amount, 0.5)
    }

    func testPortableIntentCanBeEncodedWithoutThirdPartyModels() throws {
        let original = try interpret(
            "A warm physical modeling pluck, without noisy bells.",
            mode: .create)
        XCTAssertEqual(original.engineHints, [.physical])
        XCTAssertEqual(original.role, .pluck)
        XCTAssertEqual(Set(original.excludedFamilies), Set([.noise, .bells]))
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StudioSoundDescriptionIntent.self,
                                                from: data)
        XCTAssertEqual(restored, original)
    }

    func testInterpretingTextDoesNotMutateExistingSynthPatches() throws {
        var sound = StudioSynthPatch.individual(.analog)
        let original = sound
        _ = try interpret("A bright wavetable pad with slow attack.")
        XCTAssertEqual(sound, original)
        XCTAssertTrue(sound.validate())
        sound.layers[0].gain = 0.35
        XCTAssertEqual(original.layers[0].gain, 0.75)
    }
}
