import Foundation
import XCTest
@testable import DAWCore

@MainActor
final class StudioSoundPatchRefinerTests: XCTestCase {
    private func sound(_ prompt: String) throws -> StudioSynthPatch {
        try StudioSoundPatchGenerator.generate(description: prompt).patch
    }

    func testDarkerSlowerAttackAndFullerLowEndChangeOnlyRequestedAnalogControls() throws {
        var original = try sound("bright analog pad")
        var analog = try XCTUnwrap(original.layers[0].analogPatch)
        analog.set(0.72, for: .pulseWidth) // A hand-edited parameter must survive.
        analog.set(0.33, for: .noiseLevel)
        original.layers[0].analogPatch = analog
        let result = try StudioSoundPatchRefiner.refine(
            "Make it darker, slow down the attack, and give it a fuller low end",
            patch: original)
        XCTAssertTrue(result.patch.validate())
        XCTAssertEqual(result.before, original)
        XCTAssertEqual(original.layers[0].id, result.patch.layers[0].id)
        let edited = try XCTUnwrap(result.patch.layers[0].analogPatch)
        XCTAssertLessThan(edited.value(for: .filterCutoff),
                          analog.value(for: .filterCutoff))
        XCTAssertGreaterThan(edited.value(for: .amplitudeAttack),
                             analog.value(for: .amplitudeAttack))
        XCTAssertGreaterThan(edited.value(for: .oscillator2Level),
                             analog.value(for: .oscillator2Level))
        XCTAssertEqual(edited.value(for: .pulseWidth), 0.72)
        XCTAssertEqual(edited.value(for: .noiseLevel), 0.33)
        XCTAssertEqual(result.patch.layers[0].gain, original.layers[0].gain)
        XCTAssertGreaterThanOrEqual(result.changes.count, 3)
    }

    func testAllSixEnginesRefineBrightnessAndKeepTheirIdentity() throws {
        let prompts = [
            "warm analog lead", "metallic FM key", "wavetable pad",
            "additive strings", "granular texture", "physical modeling brass"
        ]
        for prompt in prompts {
            let original = try sound(prompt)
            XCTAssertEqual(original.layers.count, 1, prompt)
            let result = try StudioSoundPatchRefiner.refine(
                "a little brighter", patch: original)
            XCTAssertTrue(result.patch.validate(), prompt)
            XCTAssertFalse(result.changes.isEmpty, prompt)
            XCTAssertEqual(result.patch.layers.map(\.id),
                           original.layers.map(\.id), prompt)
            XCTAssertEqual(result.patch.layers.map(\.engine),
                           original.layers.map(\.engine), prompt)
            XCTAssertEqual(result.patch.layers.map(\.name),
                           original.layers.map(\.name), prompt)
            XCTAssertEqual(result.patch.layers.map(\.gain),
                           original.layers.map(\.gain), prompt)
        }
    }

    func testHybridLayerRoutingAndUnselectedEngineArePreserved() throws {
        var original = try sound("An evolving analog and additive pad")
        let first = original.layers[0].id
        let second = original.layers[1].id
        let originalModulation = original.modulation
        original.layers[0].enabled = false
        let result = try StudioSoundPatchRefiner.refine(
            "Make the additive part darker", patch: original)
        XCTAssertEqual(result.patch.layers[0], original.layers[0])
        XCTAssertNotEqual(result.patch.layers[1], original.layers[1])
        XCTAssertEqual(result.patch.layers.map(\.id), [first, second])
        XCTAssertEqual(result.patch.modulation, originalModulation)
        XCTAssertEqual(result.patch.midiControls, original.midiControls)
        XCTAssertTrue(result.changes.allSatisfy { $0.layerID == second })
    }

    func testImportedGranularSourceAndExistingModulationRemainUntouched() throws {
        var original = try sound("granular texture with movement")
        var granular = try XCTUnwrap(original.layers[0].granularPatch)
        granular.importedAudioPath = "/Users/composer/Samples/custom texture.wav"
        granular.source = .strings
        original.layers[0].granularPatch = granular
        let mod = original.modulation
        let result = try StudioSoundPatchRefiner.refine(
            "Make it darker and give it more movement", patch: original)
        let updated = try XCTUnwrap(result.patch.layers[0].granularPatch)
        XCTAssertEqual(updated.importedAudioPath, granular.importedAudioPath)
        XCTAssertEqual(updated.source, granular.source)
        XCTAssertEqual(result.patch.modulation, mod)
        XCTAssertTrue(result.patch.validate())
    }

    func testWidthRefinementDoesNotAffectGainOrHallRouting() throws {
        let original = try sound("warm strings pad with shimmering harmonics")
        XCTAssertGreaterThan(original.layers.count, 1)
        let result = try StudioSoundPatchRefiner.refine(
            "Make it wider", patch: original)
        XCTAssertEqual(result.patch.layers.map(\.gain),
                       original.layers.map(\.gain))
        XCTAssertEqual(result.patch.modulation, original.modulation)
        XCTAssertEqual(result.patch.layers.map(\.id), original.layers.map(\.id))
        XCTAssertTrue(result.changes.contains { $0.control == "Layer Pan" })
        XCTAssertTrue(result.limitations.contains { $0.contains("no reverb") })
    }

    func testPhysicalAttackRefinementClearlyReportsItsApproximation() throws {
        let original = try sound("physical modeling string pluck")
        let result = try StudioSoundPatchRefiner.refine(
            "a slower attack", patch: original)
        XCTAssertTrue(result.patch.validate())
        XCTAssertTrue(result.limitations.contains {
            $0.contains("no general attack envelope")
        })
        XCTAssertEqual(result.patch.layers[0].physicalPatch?.model,
                       original.layers[0].physicalPatch?.model)
    }

    func testInvalidAndUnrecognizedRequestsNeverMutateOriginal() throws {
        let original = try sound("analog pad")
        XCTAssertThrowsError(try StudioSoundPatchRefiner.refine(
            "Make it more like a bicycle", patch: original)) {
            XCTAssertEqual($0 as? StudioSoundPatchRefinementError,
                           .noQualityInstruction)
        }
        XCTAssertThrowsError(try StudioSoundPatchRefiner.refine(
            "Make the FM part brighter", patch: original)) {
            XCTAssertEqual($0 as? StudioSoundPatchRefinementError,
                           .noMatchingLayer)
        }
        XCTAssertThrowsError(try StudioSoundPatchRefiner.refine(
            "Make it wider", patch: original)) {
            XCTAssertEqual($0 as? StudioSoundPatchRefinementError,
                           .noEffectiveChange)
        }
        XCTAssertEqual(original, try sound("analog pad"))
    }

    func testHistoryUndoRedoAndRebranching() throws {
        let original = try sound("analog lead")
        var history = try StudioSoundRefinementHistory(patch: original)
        let darker = try history.refine("darker")
        let slower = try history.refine("slower attack")
        XCTAssertEqual(history.cursor, 2)
        XCTAssertEqual(history.currentPatch, slower.patch)
        XCTAssertEqual(history.undo(), darker.patch)
        XCTAssertEqual(history.undo(), original)
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.redo(), darker.patch)
        XCTAssertTrue(history.canRedo)

        // Failed text must not throw away the redo branch.
        XCTAssertThrowsError(try history.refine("make it a bicycle"))
        XCTAssertTrue(history.canRedo)
        let replacement = try history.refine("warmer")
        XCTAssertEqual(history.steps.count, 2)
        XCTAssertEqual(history.currentPatch, replacement.patch)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo(), darker.patch)
        XCTAssertEqual(history.redo(), replacement.patch)
        try history.reset(to: original)
        XCTAssertEqual(history.currentPatch, original)
        XCTAssertFalse(history.canUndo)
    }

    func testHistoryIsBoundedAndRefinementRoundTripsThroughPortablePatchJSON() throws {
        let original = try sound("analog lead")
        var history = try StudioSoundRefinementHistory(patch: original)
        for index in 0..<50 {
            // Alternation avoids saturating native controls.
            try history.refine(index.isMultiple(of: 2) ? "darker" : "brighter")
        }
        XCTAssertEqual(history.steps.count, StudioSoundRefinementHistory.maximumSteps)
        XCTAssertEqual(history.cursor, StudioSoundRefinementHistory.maximumSteps)
        XCTAssertTrue(history.currentPatch.validate())
        let json = try JSONEncoder().encode(history.currentPatch)
        XCTAssertEqual(try JSONDecoder().decode(StudioSynthPatch.self, from: json),
                       history.currentPatch)
    }

    func testExistingGeneratorStillRejectsRefinementMode() throws {
        let intent = try StudioSoundDescriptionInterpreter.interpret(
            "warmer", mode: .refine)
        XCTAssertThrowsError(try StudioSoundPatchGenerator.generate(from: intent)) {
            XCTAssertEqual($0 as? StudioSoundPatchGenerationError,
                           .refinementRequiresExistingSound)
        }
        XCTAssertThrowsError(try StudioSoundPatchRefiner.refine(
            from: try StudioSoundDescriptionInterpreter.interpret("warmer"),
            patch: try sound("analog pad"))) {
            XCTAssertEqual($0 as? StudioSoundPatchRefinementError,
                           .requiresRefinementIntent)
        }
    }
}
