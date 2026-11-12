import XCTest
import Foundation
@testable import DAWCore

@MainActor
final class StudioSynthModulationTests: XCTestCase {
    private func threeEngines() -> StudioSynthPatch {
        var patch = StudioSynthPatch()
        patch.layers.append(StudioSynthLayer(engine: .wavetable))
        return patch
    }

    func testPortableMatrixWithIndependentDestinations() throws {
        var patch = threeEngines()
        let ids = patch.layers.map(\.id)
        var settings = StudioSynthModulationSettings()
        settings.routes = [
            StudioSynthModRoute(source: .lfo1, layerID: ids[0],
                                destination: .analog(.filterCutoff), depth: 0.5),
            StudioSynthModRoute(source: .modWheel, layerID: ids[1],
                                destination: .fm(.op2Level), depth: -0.4),
            StudioSynthModRoute(source: .envelope, layerID: ids[2],
                                destination: .wavetable(.osc1Position), depth: 0.6),
            StudioSynthModRoute(source: .macro1, layerID: ids[2],
                                destination: .wavetable(.partial5), depth: 0.3)
        ]
        patch.modulation = settings
        XCTAssertTrue(patch.validate())
        XCTAssertEqual(settings.routes.count, 4)
        XCTAssertEqual(StudioSynthModDestination.available(for: .analog).count, 8)
        XCTAssertGreaterThan(StudioSynthModDestination.available(for: .wavetable).count, 16)
        let encoded = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(StudioSynthPatch.self, from: encoded)
        XCTAssertEqual(decoded, patch)
        XCTAssertEqual(decoded.modulation?.routes[2].source, .envelope)
    }

    func testRoutingRejectsInvalidTargetsDepthAndLimits() {
        var patch = threeEngines()
        let id = patch.layers[0].id
        var settings = StudioSynthModulationSettings()
        settings.routes = [
            StudioSynthModRoute(source: .lfo1, layerID: id,
                                destination: .fm(.feedback), depth: 0.5)
        ]
        patch.modulation = settings
        XCTAssertFalse(patch.validate(), "FM destination cannot target Analog")
        settings.routes[0].destination = .analog(.oscillator1Wave)
        patch.modulation = settings
        XCTAssertFalse(patch.validate(), "Discrete waveform selection cannot be swept")
        settings.routes[0].destination = .analog(.filterCutoff)
        settings.routes[0].depth = 1.2
        patch.modulation = settings
        XCTAssertFalse(patch.validate())
        settings.routes[0].depth = .nan
        patch.modulation = settings
        XCTAssertFalse(patch.validate())
        settings.routes[0].depth = 0.4
        settings.routes.append(settings.routes[0])
        patch.modulation = settings
        XCTAssertFalse(patch.validate(), "Duplicate modulation route UUID")
        settings.routes = (0..<25).map { _ in
            StudioSynthModRoute(source: .lfo2, layerID: id,
                                destination: .analog(.filterCutoff))
        }
        patch.modulation = settings
        XCTAssertFalse(patch.validate(), "Limit is 24 routes")
        settings.routes = []
        settings.lfo1Rate = .nan
        patch.modulation = settings
        XCTAssertFalse(patch.validate())
        settings.lfo1Rate = 1
        settings.macro1 = 0.6
        patch.modulation = settings
        XCTAssertTrue(patch.validate())
    }

    func testOldHybridProjectDecodesWithoutMatrix() throws {
        let original = StudioSynthPatch()
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)) as? [String: Any])
        encoded.removeValue(forKey: "modulation")
        let decoded = try JSONDecoder().decode(StudioSynthPatch.self,
                     from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(decoded.modulation)
        XCTAssertTrue(decoded.validate())
    }

    func testPureLFOAndEnvelopeControlSignals() {
        var settings = StudioSynthModulationSettings()
        settings.lfo1Rate = 1
        settings.lfo2Rate = 1
        settings.macro1 = 0.8
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo1, seconds: 0.25, settings: settings, envelope: 0, wheel: 0),
            1, accuracy: 0.001)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo2, seconds: 0.5, settings: settings, envelope: 0, wheel: 0),
            1, accuracy: 0.001)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo2, seconds: 0, settings: settings, envelope: 0, wheel: 0),
            -1, accuracy: 0.001)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .modWheel, seconds: 0, settings: settings, envelope: 0, wheel: 0.4),
            0.4, accuracy: 0.001)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .macro1, seconds: 0, settings: settings, envelope: 0, wheel: 0),
            0.8, accuracy: 0.001)

        var adsr = StudioSynthModulationEnvelope()
        adsr.trigger()
        XCTAssertEqual(adsr.advance(seconds: 0.08, settings: settings), 1,
                       accuracy: 0.001)
        // The control worker caps each time step at 200 ms to avoid a
        // long scheduler stall jumping an envelope multiple stages.
        _ = adsr.advance(seconds: 0.15, settings: settings)
        XCTAssertEqual(adsr.advance(seconds: 0.15, settings: settings), 0.7,
                       accuracy: 0.001)
        adsr.release()
        XCTAssertGreaterThan(adsr.advance(seconds: 0.2, settings: settings), 0)
        _ = adsr.advance(seconds: 0.2, settings: settings)
        XCTAssertEqual(adsr.advance(seconds: 0.2, settings: settings), 0,
                       accuracy: 0.001)
        adsr.reset()
        XCTAssertEqual(adsr.value, 0)
    }

    func testTempoSyncedLFOsUseMusicalDivisionsWithoutChangingFreeRates() throws {
        var settings = StudioSynthModulationSettings(lfo1Rate: 1,
                                                     lfo2Rate: 1)
        // Old projects have no sync keys and must retain their Hz behavior.
        let oldJSON = try JSONEncoder().encode(settings)
        let old = try JSONDecoder().decode(
            StudioSynthModulationSettings.self, from: oldJSON)
        XCTAssertNil(old.lfo1Sync)
        XCTAssertNil(old.lfo2Sync)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo1, seconds: 0.25, settings: old,
            envelope: 0, wheel: 0, bpm: 60), 1, accuracy: 0.001)

        settings.lfo1Sync = StudioSynthLFOSync(note: .quarter)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo1, seconds: 0.125, settings: settings,
            envelope: 0, wheel: 0, bpm: 120), 1, accuracy: 0.001)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo1, seconds: 0.25, settings: settings,
            envelope: 0, wheel: 0, bpm: 60), 1, accuracy: 0.001)

        // Dotted notes are 3/2 the duration; triplets are 2/3.
        settings.lfo1Sync = StudioSynthLFOSync(note: .quarter,
                                               timing: .dotted)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo1, seconds: 0.1875, settings: settings,
            envelope: 0, wheel: 0, bpm: 120), 1, accuracy: 0.001)
        settings.lfo1Sync = StudioSynthLFOSync(note: .quarter,
                                               timing: .triplet)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo1, seconds: 1.0 / 12, settings: settings,
            envelope: 0, wheel: 0, bpm: 120), 1, accuracy: 0.001)

        // Every note division produces exactly one cycle in its stated beats.
        for note in StudioSynthLFONote.allCases {
            for timing in StudioSynthLFOTiming.allCases {
                settings.lfo1Sync = StudioSynthLFOSync(note: note, timing: timing)
                let quarterCycleSeconds = note.beats * timing.multiplier / 8
                XCTAssertEqual(StudioSynthModulationMath.signal(
                    .lfo1, seconds: quarterCycleSeconds, settings: settings,
                    envelope: 0, wheel: 0, bpm: 120), 1, accuracy: 0.001)
            }
        }

        settings.lfo2Sync = StudioSynthLFOSync(note: .eighth)
        XCTAssertEqual(StudioSynthModulationMath.signal(
            .lfo2, seconds: 0.125, settings: settings,
            envelope: 0, wheel: 0, bpm: 120), 1, accuracy: 0.001)

        // The integrated beat clock survives a BPM change. A naive
        // elapsedSeconds * newBPM calculation would jump backwards.
        settings.lfo1Sync = StudioSynthLFOSync(note: .quarter)
        let afterTempoChange = StudioSynthModulationMath.signal(
            .lfo1, seconds: 0.25, settings: settings,
            envelope: 0, wheel: 0, bpm: 60, beats: 0.375)
        XCTAssertEqual(afterTempoChange, Float(sin(0.75 * Double.pi)),
                       accuracy: 0.001)

        let roundTrip = try JSONDecoder().decode(
            StudioSynthModulationSettings.self,
            from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip, settings)
        XCTAssertEqual(roundTrip.lfo1Rate, 1, "Free Hz remains stored in Sync")
    }

    func testMacroRoutesSweepThreeEnginesAndRestoreBasePatches() throws {
        let patch = threeEngines()
        let ids = patch.layers.map(\.id)
        let synth = try StudioSynthInstrument(sampleRate: 44_100, patch: patch)
        let analog = StudioSynthModDestination.analog(.filterCutoff)
        let fm = StudioSynthModDestination.fm(.feedback)
        let wavetable = StudioSynthModDestination.wavetable(.osc1Position)
        let cutoffBase = try XCTUnwrap(synth.effectiveParameter(
            id: ids[0], destination: analog))
        let fmBase = try XCTUnwrap(synth.effectiveParameter(
            id: ids[1], destination: fm))
        let waveBase = try XCTUnwrap(synth.effectiveParameter(
            id: ids[2], destination: wavetable))

        var settings = StudioSynthModulationSettings(macro1: 1)
        settings.routes = [
            StudioSynthModRoute(source: .macro1, layerID: ids[0],
                                destination: analog, depth: 0.2),
            StudioSynthModRoute(source: .macro1, layerID: ids[1],
                                destination: fm, depth: 0.35),
            StudioSynthModRoute(source: .macro1, layerID: ids[2],
                                destination: wavetable, depth: -0.25),
            StudioSynthModRoute(source: .macro1, layerID: ids[2],
                                destination: wavetable, depth: 0.10)
        ]
        XCTAssertTrue(synth.setModulation(settings))
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[0], destination: analog)),
            analog.apply(base: cutoffBase, normalizedOffset: 0.2),
            accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[1], destination: fm)),
            fm.apply(base: fmBase, normalizedOffset: 0.35),
            accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[2], destination: wavetable)),
            wavetable.apply(base: waveBase, normalizedOffset: -0.15),
            accuracy: 0.0001)

        // User parameter edits must update the unmodulated baseline, not
        // temporarily override the active modulation from the worker.
        XCTAssertTrue(synth.setFMParameter(id: ids[1], parameter: .feedback,
                                          value: 0.2))
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[1], destination: fm)),
            fm.apply(base: 0.2, normalizedOffset: 0.35),
            accuracy: 0.0001)

        settings.macro1 = 0
        XCTAssertTrue(synth.setModulation(settings))
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[1], destination: fm)), 0.2, accuracy: 0.0001)

        settings.routes.removeAll()
        XCTAssertTrue(synth.setModulation(settings))
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[0], destination: analog)),
            cutoffBase, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[1], destination: fm)), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(synth.effectiveParameter(
            id: ids[2], destination: wavetable)),
            waveBase, accuracy: 0.0001)
    }
}
