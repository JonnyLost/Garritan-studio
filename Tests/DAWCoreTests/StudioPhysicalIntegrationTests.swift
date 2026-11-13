import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioPhysicalIntegrationTests: XCTestCase {
    func testPhysicalFactorySoundsHaveDistinctPortableValidPatches() throws {
        let presets = StudioPhysicalFactoryLibrary.presets
        XCTAssertEqual(presets.count, 12)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertEqual(Set(presets.map { $0.patch.model }),
                       Set(StudioPhysicalModel.allCases))
        let encoded = try presets.map { try JSONEncoder().encode($0.patch) }
        XCTAssertEqual(Set(encoded).count, presets.count)
        for preset in presets {
            XCTAssertTrue(preset.patch.validate(), preset.name)
            XCTAssertEqual(try JSONDecoder().decode(
                StudioPhysicalPatch.self, from: JSONEncoder().encode(preset.patch)),
                           preset.patch)
        }
    }

    func testPhysicalPatchRejectsCorruptionAndModelFractions() throws {
        var patch = StudioPhysicalPatch()
        XCTAssertTrue(patch.validate())
        patch.values["0"] = 2.5
        XCTAssertFalse(patch.validate())
        patch.values["0"] = 7
        patch.values["18"] = 1.25
        XCTAssertFalse(patch.validate())
        patch.values["18"] = 0.75
        patch.values["200"] = 0.5
        XCTAssertFalse(patch.validate())
        patch.values.removeValue(forKey: "200")
        XCTAssertTrue(patch.validate())
        let sound = StudioSynthPatch(layers: [
            StudioSynthLayer(engine: .physical, physicalPatch: patch)
        ])
        XCTAssertTrue(sound.validate())
    }

    func testPhysicalEngineSavesToSynthAndTrackJSON() throws {
        var sound = StudioPhysicalPatch()
        sound.set(6, for: .model)
        sound.set(0.9, for: .percussionInharmonicity)
        let layer = StudioSynthLayer(engine: .physical,
                                     physicalPatch: sound)
        let patch = StudioSynthPatch(layers: [layer])
        XCTAssertTrue(patch.validate())
        let restored = try JSONDecoder().decode(
            StudioSynthPatch.self, from: JSONEncoder().encode(patch))
        XCTAssertEqual(restored, patch)
        var track = Track(name: "Native Physical Bell", type: .instrument)
        track.studioSynthEnabled = true
        track.studioSynthPatch = patch
        let loaded = try JSONDecoder().decode(
            Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(loaded.studioSynthPatch, patch)

        // Old StudioSynthLayer JSON had no physicalPatch property.
        let oldPatch = StudioSynthPatch()
        let oldData = try JSONEncoder().encode(oldPatch)
        let oldCopy = try JSONDecoder().decode(
            StudioSynthPatch.self, from: oldData)
        XCTAssertEqual(oldCopy.layers.first?.physicalPatch, nil)
    }

    func testPhysicalSingleLayerRendersThroughStudioAudioGraph() throws {
        let rate = 44_100.0
        var sound = StudioPhysicalPatch()
        sound.set(5, for: .model)
        sound.set(0.65, for: .percussionDecay)
        let patch = StudioSynthPatch(layers: [
            StudioSynthLayer(engine: .physical, physicalPatch: sound)
        ])
        let synth = try StudioSynthInstrument(sampleRate: rate, patch: patch)
        XCTAssertEqual(synth.auxiliaryNodes.count, 2)
        let id = try XCTUnwrap(patch.layers.first?.id)
        XCTAssertTrue(synth.setPhysicalParameter(
            id: id, parameter: .percussionHardness, value: 0.8))
        XCTAssertFalse(synth.setPhysicalParameter(
            id: id, parameter: .percussionHardness, value: 2.0))
        XCTAssertFalse(synth.setFMParameter(
            id: id, parameter: .feedback, value: 0.4))
        let audio = AVAudioEngine()
        try synth.attach(to: audio, destination: audio.mainMixerNode,
                         sampleRate: rate)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try audio.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 512)
        try audio.start()
        defer {
            audio.stop()
            audio.disableManualRenderingMode()
        }
        XCTAssertTrue(synth.noteOn(69, velocity: 127))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var peak: Float = 0
        for _ in 0..<16 {
            XCTAssertEqual(try audio.renderOffline(512, to: buffer), .success)
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<Int(buffer.frameLength) {
                let a = samples[0][frame]
                let b = samples[1][frame]
                XCTAssertTrue(a.isFinite && b.isFinite)
                peak = max(peak, abs(a), abs(b))
            }
        }
        XCTAssertGreaterThan(peak, 0.005)
        XCTAssertTrue(synth.noteOff(69))
        XCTAssertTrue(synth.allNotesOff())
    }

    func testPhysicalHybridPresetsAndModulationTargets() throws {
        let hybrids = StudioSynthHybridFactoryLibrary.presets.filter {
            $0.patch.layers.contains { $0.engine == .physical }
        }
        XCTAssertGreaterThanOrEqual(hybrids.count, 2)
        for preset in hybrids {
            XCTAssertTrue(preset.patch.validate(), preset.name)
            let synth = try StudioSynthInstrument(
                sampleRate: 44_100, patch: preset.patch)
            XCTAssertEqual(synth.auxiliaryNodes.count,
                           preset.patch.layers.filter(\.enabled).count * 2)
            XCTAssertTrue(synth.noteOn(60, velocity: 100))
            XCTAssertTrue(synth.noteOff(60))
            XCTAssertTrue(synth.allNotesOff())
        }
        let destinations = StudioSynthModDestination.available(for: .physical)
        XCTAssertEqual(destinations.count,
                       StudioPhysicalParameter.allCases.count - 1)
        XCTAssertFalse(destinations.contains(.physical(.model)))
        XCTAssertTrue(destinations.contains(.physical(.bowPressure)))
        let target = StudioSynthModDestination.physical(.breath)
        XCTAssertTrue(target.isContinuouslyModulatable)
        XCTAssertEqual(target.engine, .physical)
        XCTAssertTrue(target.valid(target.defaultValue))
        XCTAssertEqual(target.value(at: target.position(for: 0.85)),
                       0.85, accuracy: 0.0001)
    }

    func testPhysicalEngineSupportsAllModelsAndMIDIEvents() throws {
        for model in StudioPhysicalModel.allCases {
            var sound = StudioPhysicalPatch()
            sound.set(Float(model.rawValue), for: .model)
            let synth = try StudioPhysicalInstrument(
                sampleRate: 48_000, patch: sound)
            XCTAssertEqual(synth.parameter(.model), Float(model.rawValue))
            XCTAssertTrue(synth.noteOn(60, velocity: 110, channel: 2))
            XCTAssertTrue(synth.controller(11, value: 100, channel: 2))
            XCTAssertTrue(synth.midiMessage(status: 0xE2, data1: 0,
                                             data2: 64))
            XCTAssertTrue(synth.noteOff(60, channel: 2))
            XCTAssertTrue(synth.allNotesOff())
        }
    }
}
