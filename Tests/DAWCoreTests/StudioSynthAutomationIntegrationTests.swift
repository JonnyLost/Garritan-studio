import XCTest
import Foundation
@testable import DAWCore

@MainActor
final class StudioSynthAutomationIntegrationTests: XCTestCase {
    private func awaitEffective(_ synth: StudioSynthInstrument,
                                layerID: UUID,
                                destination: StudioSynthModDestination,
                                expected: Float,
                                accuracy: Float = 0.002) -> Float {
        for _ in 0..<80 {
            let current = synth.effectiveParameter(
                id: layerID, destination: destination) ?? .nan
            if abs(current - expected) <= accuracy { return current }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return synth.effectiveParameter(
            id: layerID, destination: destination) ?? .nan
    }

    func testAllSixEngineAutomationTargetsRestoreSavedSound() throws {
        let targets: [(StudioSynthEngine, StudioSynthModDestination)] = [
            (.analog, .analog(.filterCutoff)),
            (.fm, .fm(.feedback)),
            (.wavetable, .wavetable(.osc1Position)),
            (.additive, .additive(.outputGain)),
            (.granular, .granular(.density)),
            (.physical, .physical(.breath))
        ]
        for (engine, destination) in targets {
            let patch = StudioSynthPatch.individual(engine)
            let id = try XCTUnwrap(patch.layers.first?.id)
            let synth = try StudioSynthInstrument(
                sampleRate: 44_100, patch: patch)
            let original = try XCTUnwrap(synth.effectiveParameter(
                id: id, destination: destination))
            let target = destination.value(at: 0.76)
            XCTAssertTrue(synth.setAutomation(
                layerID: id, destination: destination, normalized: 0.76),
                engine.title)
            XCTAssertEqual(awaitEffective(synth, layerID: id,
                                         destination: destination,
                                         expected: target),
                           target, accuracy: 0.002, engine.title)
            // Automation must not bake temporary performance values into
            // the instrument preset or persistent project patch.
            XCTAssertEqual(synth.patch, patch)
            synth.clearAutomation()
            XCTAssertEqual(awaitEffective(synth, layerID: id,
                                         destination: destination,
                                         expected: original),
                           original, accuracy: 0.002, engine.title)
            XCTAssertFalse(synth.setAutomation(
                layerID: UUID(), destination: destination, normalized: 0.5))
            XCTAssertFalse(synth.setAutomation(
                layerID: id, destination: destination, normalized: .nan))
        }
    }

    func testAutomationOverridesCCAndRestoresMappedControllerWhenStopped() throws {
        var patch = StudioSynthPatch.individual(.analog)
        let id = try XCTUnwrap(patch.layers.first?.id)
        let destination = StudioSynthModDestination.analog(.filterCutoff)
        patch.midiControls = StudioSynthMIDIControlSettings(mappings: [
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: id, destination: destination))
        ])
        let synth = try StudioSynthInstrument(sampleRate: 44_100,
                                               patch: patch)
        XCTAssertTrue(synth.controller(74, value: 32))
        let expectedCC = destination.value(at: Double(32) / 127)
        XCTAssertEqual(awaitEffective(synth, layerID: id,
                                     destination: destination,
                                     expected: expectedCC),
                       expectedCC, accuracy: 0.002)
        XCTAssertTrue(synth.setAutomation(
            layerID: id, destination: destination, normalized: 0.9))
        let expectedAutomation = destination.value(at: 0.9)
        XCTAssertEqual(awaitEffective(synth, layerID: id,
                                     destination: destination,
                                     expected: expectedAutomation),
                       expectedAutomation, accuracy: 0.002)
        synth.clearAutomation()
        XCTAssertEqual(awaitEffective(synth, layerID: id,
                                     destination: destination,
                                     expected: expectedCC),
                       expectedCC, accuracy: 0.002)
        XCTAssertEqual(synth.patch, patch)
    }

    func testAutomationLanePersistsAcrossProjectJSONAndInterpolates() throws {
        var track = Track(name: "Granular Motion", type: .instrument)
        let patch = StudioSynthPatch.individual(.granular)
        track.studioSynthEnabled = true
        track.studioSynthPatch = patch
        let id = try XCTUnwrap(patch.layers.first?.id)
        let destination = StudioSynthModDestination.granular(.position)
        var lane = AutomationLane(
            parameter: .studioSynth(layerID: id, destination: destination))
        lane.setPoint(at: 0, value: 0.1)
        lane.setPoint(at: 4, value: 0.9)
        track.automationLanes.append(lane)
        XCTAssertEqual(lane.value(atBeat: 2), 0.5, accuracy: 0.0001)
        let persisted = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(persisted.automationLanes.count,
                       track.automationLanes.count)
        let restored = try XCTUnwrap(persisted.automationLanes.last)
        XCTAssertEqual(restored.parameter, lane.parameter)
        XCTAssertEqual(restored.value(atBeat: 2), 0.5, accuracy: 0.0001)
        XCTAssertTrue(persisted.studioSynthPatch?.validate() == true)
    }

    func testAutomationRejectsMismatchedEngineAndDiscreteParameters() throws {
        let patch = StudioSynthPatch.individual(.physical)
        let id = try XCTUnwrap(patch.layers.first?.id)
        let synth = try StudioSynthInstrument(sampleRate: 44_100,
                                               patch: patch)
        XCTAssertFalse(synth.setAutomation(layerID: id,
                                            destination: .fm(.feedback),
                                            normalized: 0.5))
        XCTAssertFalse(synth.setAutomation(layerID: id,
                                            destination: .physical(.model),
                                            normalized: 0.5))
        XCTAssertFalse(synth.setAutomation(layerID: id,
                                            destination: .physical(.breath),
                                            normalized: 1.1))
    }
}
