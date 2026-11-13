import XCTest
import Foundation
@testable import DAWCore

@MainActor
final class StudioSynthMIDILearnTests: XCTestCase {
    private func threeEngines() -> StudioSynthPatch {
        var patch = StudioSynthPatch()
        patch.layers.append(StudioSynthLayer(engine: .wavetable))
        return patch
    }

    private func waitFor(_ synth: StudioSynthInstrument, layer: UUID,
                         destination: StudioSynthModDestination,
                         expected: Float, accuracy: Float = 0.002) -> Float {
        for _ in 0..<80 {
            if let value = synth.effectiveParameter(id: layer,
                                                    destination: destination),
               abs(value - expected) <= accuracy {
                return value
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return synth.effectiveParameter(id: layer, destination: destination)
            ?? .nan
    }

    func testControllerMappingSerializationAcrossAllSynthesisEngines() throws {
        var patch = threeEngines()
        let ids = patch.layers.map(\.id)
        patch.midiControls = StudioSynthMIDIControlSettings(mappings: [
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: ids[0], destination: .analog(.filterCutoff)),
                minimum: 0.2, maximum: 0.8),
            StudioSynthMIDIControlMapping(
                controller: 74, channel: 2, target: .parameter(
                    layerID: ids[1], destination: .fm(.feedback)),
                minimum: 1, maximum: 0),
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: ids[2], destination: .wavetable(.osc1Position))),
            StudioSynthMIDIControlMapping(controller: 71, target: .macro1)
        ])
        XCTAssertTrue(patch.validate())
        let encoded = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(StudioSynthPatch.self, from: encoded)
        XCTAssertEqual(decoded, patch)
        XCTAssertEqual(decoded.midiControls?.mappings.count, 4)
    }

    func testOldPatchesDecodeWithoutAnyMIDIControlSettings() throws {
        var original = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(StudioSynthPatch())) as? [String: Any])
        original.removeValue(forKey: "midiControls")
        let decoded = try JSONDecoder().decode(StudioSynthPatch.self,
            from: JSONSerialization.data(withJSONObject: original))
        XCTAssertNil(decoded.midiControls)
        XCTAssertTrue(decoded.validate())
    }

    func testMappingValidationRangeChannelReservedCCAndDestinationOwnership() {
        let patch = threeEngines()
        let id = patch.layers[0].id
        let target = StudioSynthMIDIControlTarget.parameter(
            layerID: id, destination: .analog(.filterCutoff))
        var mapping = StudioSynthMIDIControlMapping(controller: 74, target: target)
        XCTAssertTrue(mapping.validate(layers: patch.layers))
        XCTAssertFalse(StudioSynthMIDIControlMapping.supportsController(0))
        XCTAssertFalse(StudioSynthMIDIControlMapping.supportsController(64))
        XCTAssertFalse(StudioSynthMIDIControlMapping.supportsController(123))
        mapping.controller = 64
        XCTAssertFalse(mapping.validate(layers: patch.layers))
        mapping.controller = 74
        mapping.channel = 16
        XCTAssertFalse(mapping.validate(layers: patch.layers))
        mapping.channel = nil
        mapping.minimum = -.01
        XCTAssertFalse(mapping.validate(layers: patch.layers))
        mapping.minimum = 0
        mapping.maximum = .nan
        XCTAssertFalse(mapping.validate(layers: patch.layers))
        mapping.maximum = 1
        var controls = StudioSynthMIDIControlSettings(mappings: [mapping])
        XCTAssertTrue(controls.validate(layers: patch.layers))
        controls.mappings.append(StudioSynthMIDIControlMapping(
            controller: 71, target: target))
        XCTAssertFalse(controls.validate(layers: patch.layers),
                       "A destination must not be owned by two controllers")
        controls.mappings.removeLast()
        controls.mappings[0].target = .parameter(
            layerID: id, destination: .fm(.feedback))
        XCTAssertFalse(controls.validate(layers: patch.layers))
        controls.mappings[0].target = .parameter(
            layerID: id, destination: .analog(.oscillator1Wave))
        XCTAssertFalse(controls.validate(layers: patch.layers),
                       "Discrete waveform selectors are not MIDI-sweep targets")
    }

    func testReverseSweepAndMIDIChannelSelection() {
        let mapping = StudioSynthMIDIControlMapping(
            controller: 74, channel: 2, target: .macro1,
            minimum: 0.9, maximum: 0.1)
        XCTAssertEqual(mapping.position(for: 0)!, 0.9, accuracy: 0.0001)
        XCTAssertEqual(mapping.position(for: 127)!, 0.1, accuracy: 0.0001)
        XCTAssertEqual(mapping.position(for: 64)!, 0.9 - 0.8 * 64 / 127,
                       accuracy: 0.0001)
        XCTAssertTrue(mapping.matches(controller: 74, channel: 2))
        XCTAssertFalse(mapping.matches(controller: 74, channel: 0))
        XCTAssertFalse(mapping.matches(controller: 73, channel: 2))
        XCTAssertNil(mapping.position(for: 128))
    }

    func testLiveCCDrivesMultipleEnginesAndRestoresOriginalSound() throws {
        var patch = threeEngines()
        let ids = patch.layers.map(\.id)
        let destinations: [StudioSynthModDestination] = [
            .analog(.filterCutoff), .fm(.feedback), .wavetable(.osc1Position)
        ]
        let mappings = [
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: ids[0], destination: destinations[0]),
                minimum: 0.2, maximum: 0.8),
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: ids[1], destination: destinations[1]),
                minimum: 1, maximum: 0),
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: ids[2], destination: destinations[2]),
                minimum: 0.1, maximum: 0.9)
        ]
        patch.midiControls = StudioSynthMIDIControlSettings(mappings: mappings)
        let synth = try StudioSynthInstrument(sampleRate: 44_100, patch: patch)
        let originals = zip(ids, destinations).map {
            synth.effectiveParameter(id: $0.0, destination: $0.1)!
        }

        // CC74 is not natively understood by the original C++ synths.
        // The shared MIDI Learn worker must accept it and drive all layers.
        XCTAssertTrue(synth.controller(74, value: 127, channel: 0))
        for index in 0..<3 {
            let expected = destinations[index].value(at:
                Double(mappings[index].maximum))
            XCTAssertEqual(waitFor(synth, layer: ids[index],
                                   destination: destinations[index],
                                   expected: expected), expected, accuracy: 0.002)
        }
        XCTAssertTrue(synth.controller(74, value: 0, channel: 0))
        for index in 0..<3 {
            let expected = destinations[index].value(at:
                Double(mappings[index].minimum))
            XCTAssertEqual(waitFor(synth, layer: ids[index],
                                   destination: destinations[index],
                                   expected: expected), expected, accuracy: 0.002)
        }

        XCTAssertTrue(synth.setMIDIControls(StudioSynthMIDIControlSettings()))
        for index in 0..<3 {
            XCTAssertEqual(waitFor(synth, layer: ids[index],
                                   destination: destinations[index],
                                   expected: originals[index]),
                           originals[index], accuracy: 0.002)
        }
    }

    func testMacro1ControllerCombinesWithExistingModulation() throws {
        var patch = StudioSynthPatch.individual(.analog)
        let id = try XCTUnwrap(patch.layers.first?.id)
        let dest = StudioSynthModDestination.analog(.resonance)
        var mod = StudioSynthModulationSettings()
        mod.routes = [StudioSynthModRoute(source: .macro1,
                                         layerID: id, destination: dest,
                                         depth: 0.4)]
        patch.modulation = mod
        patch.midiControls = StudioSynthMIDIControlSettings(mappings: [
            StudioSynthMIDIControlMapping(controller: 71, target: .macro1)
        ])
        XCTAssertTrue(patch.validate())
        let synth = try StudioSynthInstrument(sampleRate: 44_100, patch: patch)
        let base = try XCTUnwrap(synth.effectiveParameter(id: id, destination: dest))
        XCTAssertTrue(synth.controller(71, value: 127))
        let target = dest.apply(base: base, normalizedOffset: 0.4)
        XCTAssertEqual(waitFor(synth, layer: id, destination: dest,
                               expected: target), target, accuracy: 0.002)
        XCTAssertTrue(synth.setMIDIControls(StudioSynthMIDIControlSettings()))
        XCTAssertEqual(waitFor(synth, layer: id, destination: dest,
                               expected: base), base, accuracy: 0.002)
    }
}
