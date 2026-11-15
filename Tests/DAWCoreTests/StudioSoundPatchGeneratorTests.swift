import Foundation
import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioSoundPatchGeneratorTests: XCTestCase {
    private func generate(_ text: String) throws -> StudioSoundGenerationResult {
        try StudioSoundPatchGenerator.generate(description: text)
    }

    func testCinematicBriefProducesEditableThreeEngineHybrid() throws {
        let result = try generate(
            "A dark, cinematic string-like pad with a slow attack, warm low " +
            "frequencies, and shimmering metallic harmonics that gradually emerge. " +
            "Something mysterious and spacious.")
        XCTAssertEqual(result.patch.layers.map(\.engine), [.analog, .additive, .wavetable])
        XCTAssertEqual(result.patch.layers.count, 3)
        XCTAssertTrue(result.patch.isHybrid)
        XCTAssertTrue(result.patch.validate())
        XCTAssertEqual(result.suggestedName, "Strings Pad")
        XCTAssertEqual(result.explanation.count, 3)
        XCTAssertTrue(result.limitations.contains(where: { $0.contains("reverb") }))
        XCTAssertNotNil(result.patch.layers[0].analogPatch)
        XCTAssertNotNil(result.patch.layers[1].additivePatch)
        XCTAssertNotNil(result.patch.layers[2].wavetablePatch)
        XCTAssertNotNil(result.patch.modulation)
        XCTAssertTrue(result.patch.modulation?.hasEnabledRoutes ?? false)
        XCTAssertTrue(result.patch.layers.allSatisfy { $0.gain <= 0.4 })
    }

    func testAllSixNativeEnginesCanBeExplicitlySelected() throws {
        let requests: [(String, StudioSynthEngine)] = [
            ("warm analog lead", .analog),
            ("metallic FM bell", .fm),
            ("evolving wavetable pad", .wavetable),
            ("warm additive strings", .additive),
            ("granular texture", .granular),
            ("physical modeling brass", .physical)
        ]
        for (text, engine) in requests {
            let result = try generate(text)
            XCTAssertEqual(result.patch.layers.map(\.engine), [engine], text)
            XCTAssertTrue(result.patch.validate(), text)
            let layer = try XCTUnwrap(result.patch.layers.first)
            XCTAssertNotNil(layer.id)
            switch engine {
            case .analog: XCTAssertNotNil(layer.analogPatch)
            case .fm: XCTAssertNotNil(layer.fmPatch)
            case .wavetable: XCTAssertNotNil(layer.wavetablePatch)
            case .additive: XCTAssertNotNil(layer.additivePatch)
            case .granular:
                XCTAssertNotNil(layer.granularPatch)
                XCTAssertNil(layer.granularPatch?.importedAudioPath)
            case .physical: XCTAssertNotNil(layer.physicalPatch)
            }
        }
    }

    func testParameterMappingChangesAudibleSynthesisSettings() throws {
        let bright = try generate("bright analog lead")
        let dark = try generate("dark analog lead")
        let brightFilter = try XCTUnwrap(bright.patch.layers[0].analogPatch)
            .value(for: .filterCutoff)
        let darkFilter = try XCTUnwrap(dark.patch.layers[0].analogPatch)
            .value(for: .filterCutoff)
        XCTAssertGreaterThan(brightFilter, darkFilter * 3)

        let fast = try generate("fast attack analog pad with short release")
        let slow = try generate("slow attack analog pad with long release")
        let fastSound = try XCTUnwrap(fast.patch.layers[0].analogPatch)
        let slowSound = try XCTUnwrap(slow.patch.layers[0].analogPatch)
        XCTAssertGreaterThan(slowSound.value(for: .amplitudeAttack),
                             fastSound.value(for: .amplitudeAttack))
        XCTAssertGreaterThan(slowSound.value(for: .amplitudeRelease),
                             fastSound.value(for: .amplitudeRelease))
    }

    func testExplicitFourEngineHybridRespectsMaximumAndRouteTargets() throws {
        let result = try generate(
            "An evolving analog FM wavetable additive pad with slow attack.")
        XCTAssertEqual(result.patch.layers.map(\.engine),
                       [.analog, .fm, .wavetable, .additive])
        XCTAssertTrue(result.patch.validate())
        XCTAssertEqual(result.patch.layers.count, 4)
        XCTAssertEqual(Set(result.patch.layers.map(\.id)).count, 4)
        let routes = try XCTUnwrap(result.patch.modulation?.routes)
        XCTAssertEqual(routes.count, 2)
        for route in routes {
            let layer = try XCTUnwrap(result.patch.layers.first {
                $0.id == route.layerID
            })
            XCTAssertEqual(route.destination.engine, layer.engine)
            XCTAssertTrue(route.destination.isContinuouslyModulatable)
        }
    }

    func testFiveExplicitEnginesProduceExplanatoryErrorInsteadOfSilentTruncation() throws {
        XCTAssertThrowsError(try generate(
            "Analog FM wavetable additive granular physical modeling pad")) { error in
            XCTAssertEqual(error as? StudioSoundPatchGenerationError, .tooManyEngines)
        }
    }

    func testExclusionsAreRespectedByEngineSelectorAndSampleSources() throws {
        let result = try generate(
            "A moving texture, avoid granular and physical modeling.")
        XCTAssertEqual(result.patch.layers.map(\.engine), [.wavetable])
        XCTAssertTrue(result.patch.validate())
        let granular = try generate(
            "A granular texture without bells and without noise")
        XCTAssertEqual(granular.patch.layers.map(\.engine), [.granular])
        let patch = try XCTUnwrap(granular.patch.layers.first?.granularPatch)
        XCTAssertNotEqual(patch.source, .bells)
        XCTAssertNotEqual(patch.source, .noise)
        XCTAssertNil(patch.importedAudioPath)
    }

    func testNoEnginesRemainingReturnsTypedError() throws {
        let intent = StudioSoundDescriptionIntent(
            originalText: "A pad", mode: .create, role: .pad,
            families: [], excludedFamilies: [], engineHints: [],
            excludedEngines: StudioSynthEngine.allCases,
            instructions: [], recognizedPhrases: ["pad"])
        XCTAssertThrowsError(try StudioSoundPatchGenerator.generate(from: intent)) {
            error in
            XCTAssertEqual(error as? StudioSoundPatchGenerationError, .noAvailableEngine)
        }
    }

    func testPhysicalModelsFollowRequestedAcousticFamily() throws {
        let brass = try generate("A warm physical modeling brass lead")
        let horn = try XCTUnwrap(brass.patch.layers[0].physicalPatch)
        XCTAssertEqual(horn.model, .brass)
        let strings = try generate("A soft physical modeling strings pad")
        let bowed = try XCTUnwrap(strings.patch.layers[0].physicalPatch)
        XCTAssertEqual(bowed.model, .bowed)
        XCTAssertTrue(strings.limitations.contains(where: { $0.contains("attack") }) == false)
    }

    func testGranularGenerationRequiresNoExternalSampleFiles() throws {
        for prompt in [
            "A granular pad of warm string clouds",
            "A noisy granular texture with metallic shimmer",
            "A granular bass with strong low end",
            "A granular bell-like texture"
        ] {
            let result = try generate(prompt)
            let patch = try XCTUnwrap(result.patch.layers.first?.granularPatch)
            XCTAssertNil(patch.importedAudioPath, prompt)
            XCTAssertTrue(patch.validate(), prompt)
        }
    }

    func testPortableProjectAndPresetStoreRoundTrip() throws {
        let result = try generate("An evolving warm FM and additive choir pad")
        let patch = result.patch
        XCTAssertTrue(patch.validate())
        let restored = try JSONDecoder().decode(
            StudioSynthPatch.self, from: JSONEncoder().encode(patch))
        XCTAssertEqual(restored, patch)

        var track = Track(name: "AI Sound Draft", type: .instrument)
        track.studioSynthEnabled = true
        track.studioSynthPatch = patch
        let reloaded = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(reloaded.studioSynthPatch, patch)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sound-designer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let preset = try StudioSynthUserPresetLibrary.save(
            name: result.suggestedName, patch: patch, in: folder)
        let loaded = try StudioSynthUserPresetLibrary.load(from:
            StudioSynthUserPresetLibrary.fileURL(for: preset, in: folder))
        XCTAssertEqual(loaded.patch, patch)
    }

    func testGeneratedSoundsInstantiateNativeAudioInstruments() throws {
        let prompts = [
            "A bright analog lead with fast attack",
            "A metallic FM key with fast attack",
            "A sharp wavetable lead with fast attack",
            "An additive bell with fast attack",
            "A granular key with fast attack",
            "A bright physical modeling string pluck",
            "A warm evolving analog and additive pad"
        ]
        for prompt in prompts {
            let generated = try generate(prompt)
            let instrument = try StudioSynthInstrument(
                sampleRate: 44_100, patch: generated.patch)
            XCTAssertTrue(instrument.noteOn(60, velocity: 100), prompt)
            XCTAssertTrue(instrument.noteOff(60), prompt)
            XCTAssertTrue(instrument.allNotesOff(), prompt)
        }
    }

    func testSameDescriptionProducesExactlyTheSamePatchIncludingRoutingIDs() throws {
        let prompt = "A warm shimmering strings pad with movement and slow attack"
        let first = try generate(prompt)
        let second = try generate(prompt)
        XCTAssertEqual(first.patch, second.patch)
        XCTAssertEqual(first.suggestedName, second.suggestedName)
        XCTAssertEqual(Set(first.patch.layers.map(\.id)).count,
                       first.patch.layers.count)
    }

    func testRelativeCreationModifiersStayBounded() throws {
        let result = try generate("More bright and less metallic analog lead")
        XCTAssertTrue(result.patch.validate())
        let sound = try XCTUnwrap(result.patch.layers[0].analogPatch)
        XCTAssertTrue(StudioAnalogParameter.filterCutoff.valid(
            sound.value(for: .filterCutoff)))
        XCTAssertTrue(StudioAnalogParameter.resonance.valid(
            sound.value(for: .resonance)))
    }

    func testRefinementIsNotMisrepresentedAsSoundCreation() throws {
        let instruction = try StudioSoundDescriptionInterpreter.interpret(
            "Make it a little brighter", mode: .refine)
        XCTAssertThrowsError(try StudioSoundPatchGenerator.generate(from: instruction)) {
            error in
            XCTAssertEqual(error as? StudioSoundPatchGenerationError,
                           .refinementRequiresExistingSound)
        }
    }

    func testEmptyOrExclusionOnlyBriefIsNotInventedIntoAPlayableSound() throws {
        XCTAssertThrowsError(try generate("   ")) {
            XCTAssertEqual($0 as? StudioSoundDescriptionError, .emptyDescription)
        }
        XCTAssertThrowsError(try generate("No drums, no bells")) {
            XCTAssertEqual($0 as? StudioSoundPatchGenerationError, .insufficientDescription)
        }
    }

    func testBroadRangeOfCompositionalSoundRequestsRemainValid() throws {
        let prompts = [
            "a deep analog bass with short release",
            "bright metallic FM keys with slow decay",
            "a moving wavetable lead with shimmering harmonics",
            "a warm evolving additive pad",
            "a grainy granular noise texture with a long tail",
            "a plucked physical modeling string",
            "a dark brass pad with slow attack",
            "a bright bell texture with a long release",
            "a soft woodwind lead",
            "a spacious pulsing strings pad",
            "a warm choir pad",
            "a short aggressive drum sound",
            "a clean smooth lead",
            "deep cinematic bass",
            "a noisy texture with fast attack",
            "a glassy keys patch",
            "a rich evolving synthesizer pad",
            "a slow release brass sound",
            "a very bright and aggressive sound",
            "a spacious warm texture"
        ]
        for prompt in prompts {
            let result = try generate(prompt)
            XCTAssertTrue(result.patch.validate(), prompt)
            XCTAssertTrue((1...4).contains(result.patch.layers.count), prompt)
            XCTAssertTrue(result.patch.layers.allSatisfy {
                $0.enabled && $0.gain <= 0.7
            }, prompt)
            XCTAssertEqual(Set(result.patch.layers.map(\.id)).count,
                           result.patch.layers.count, prompt)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StudioSynthPatch.self,
                    from: JSONEncoder().encode(result.patch)),
                result.patch, prompt)
        }
    }
}
