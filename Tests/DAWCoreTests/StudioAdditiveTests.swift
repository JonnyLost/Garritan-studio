import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioAdditiveTests: XCTestCase {
    func testFactoryBankContainsSixteenValidDistinctOriginalSounds() throws {
        let presets = StudioAdditiveFactoryLibrary.presets
        XCTAssertEqual(presets.count, 16)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertEqual(Set(presets.map(\.family)),
                       Set(["Keys","Winds","Pads","Bass","Plucks","Textures"]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(Set(try presets.map { try encoder.encode($0.patch) }).count,
                       presets.count)
        for preset in presets {
            XCTAssertTrue(preset.patch.validate(), preset.name)
            for parameter in StudioAdditiveParameter.allCases {
                XCTAssertTrue(parameter.valid(preset.patch.value(for: parameter)),
                              "\(preset.name) \(parameter.name)")
            }
        }
    }

    func testLegacySoundAndNewAdditiveLayerRoundTrip() throws {
        var patch = StudioSynthPatch()
        patch.layers.append(StudioSynthLayer(engine: .additive))
        XCTAssertTrue(patch.validate())
        let layerID = try XCTUnwrap(patch.layers.last?.id)
        var sound = StudioAdditivePatch()
        sound.set(0.9, for: .partial8)
        sound.set(-0.8, for: .spectralEvolution)
        patch.layers[2].additivePatch = sound
        patch.midiControls = StudioSynthMIDIControlSettings(mappings: [
            StudioSynthMIDIControlMapping(
                controller: 74,
                target: .parameter(layerID: layerID,
                                   destination: .additive(.spectralTilt)))
        ])
        XCTAssertTrue(patch.validate())
        let data = try JSONEncoder().encode(patch)
        XCTAssertEqual(try JSONDecoder().decode(StudioSynthPatch.self, from: data),
                       patch)

        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(StudioSynthPatch())) as? [String: Any])
        legacyJSON.removeValue(forKey: "midiControls")
        let original = try JSONDecoder().decode(StudioSynthPatch.self, from:
            JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertTrue(original.validate())
        XCTAssertNil(original.layers[0].additivePatch)
    }

    func testRejectsInvalidHarmonicsAndWrongEngineMappings() {
        var patch = StudioSynthPatch.individual(.additive)
        let id = patch.layers[0].id
        var sound = StudioAdditivePatch()
        sound.values["18"] = 3.4
        patch.layers[0].additivePatch = sound
        XCTAssertFalse(patch.validate())
        sound.values["18"] = 0.5
        patch.layers[0].additivePatch = sound
        XCTAssertTrue(patch.validate())
        var controls = StudioSynthMIDIControlSettings(mappings: [
            StudioSynthMIDIControlMapping(
                controller: 74, target: .parameter(
                    layerID: id,destination: .additive(.partial8)))
        ])
        patch.midiControls = controls
        XCTAssertTrue(patch.validate())
        controls.mappings[0].target = .parameter(
            layerID: id, destination: .fm(.feedback))
        patch.midiControls = controls
        XCTAssertFalse(patch.validate())
    }

    func testAdditiveRendersAndReleasesNotesOffline() throws {
        let rate = 44_100.0
        let patch = StudioSynthPatch.individual(.additive)
        let instrument = try StudioSynthInstrument(sampleRate: rate, patch: patch)
        let engine = AVAudioEngine()
        try instrument.attach(to: engine,destination: engine.mainMixerNode,
                              sampleRate: rate)
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: rate,channels: 2))
        try engine.enableManualRenderingMode(.offline,format: format,
                                             maximumFrameCount: 512)
        try engine.start()
        defer {engine.stop(); engine.disableManualRenderingMode()}
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,frameCapacity: 512))
        XCTAssertTrue(instrument.noteOn(69,velocity: 110))
        var peak: Float = 0
        for _ in 0..<15 {
            XCTAssertEqual(try engine.renderOffline(512,to: buffer), .success)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                XCTAssertTrue(channels[0][i].isFinite)
                XCTAssertTrue(channels[1][i].isFinite)
                peak = max(peak,abs(channels[0][i]),abs(channels[1][i]))
            }
        }
        XCTAssertGreaterThan(peak,0.005)
        XCTAssertTrue(instrument.noteOff(69))
        // 0.3-second default release; render > 1.15 seconds.
        for _ in 0..<100 {
            XCTAssertEqual(try engine.renderOffline(512,to: buffer), .success)
        }
        let samples = try XCTUnwrap(buffer.floatChannelData)
        var tail: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            tail=max(tail,abs(samples[0][i]),abs(samples[1][i]))
        }
        XCTAssertLessThan(tail,0.0001)
        XCTAssertTrue(instrument.allNotesOff())
    }

    func testHybridFactoryRecipesAreValidPortableAndMacBookConscious() throws {
        let presets = StudioSynthHybridFactoryLibrary.presets
        XCTAssertEqual(presets.count, 10)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        for preset in presets {
            XCTAssertTrue(preset.patch.validate(), preset.name)
            XCTAssertTrue((2...4).contains(preset.patch.layers.count), preset.name)
            XCTAssertTrue(preset.patch.layers.allSatisfy { $0.gain <= 0.45 },
                          "\(preset.name) has an unexpectedly loud layer")
            XCTAssertTrue(preset.patch.layers.contains(where: {
                $0.engine == .additive
            }), "\(preset.name) should showcase the new additive engine")
            let encoded = try JSONEncoder().encode(preset.patch)
            XCTAssertEqual(try JSONDecoder().decode(StudioSynthPatch.self,
                                                    from: encoded), preset.patch)
            XCTAssertNil(preset.patch.midiControls)
        }
        let flagship = try XCTUnwrap(presets.first(where: {
            $0.name == "Fourfold Spectrum"
        }))
        XCTAssertEqual(Set(flagship.patch.layers.map(\.engine)),
                       Set(StudioSynthEngine.allCases))
    }

    func testIndependentHarmonicParameterLayoutAndValidation() throws {
        XCTAssertEqual(StudioAdditiveParameter.allCases.count, 110)
        XCTAssertEqual(StudioAdditiveParameter.partial(15)?.rawValue, 24)
        XCTAssertNil(StudioAdditiveParameter.partial(16))
        for i in 0..<16 {
            for (control, base): (StudioAdditiveHarmonicControl, Int32) in [
                (.attack,30),(.decay,46),(.sustain,62),
                (.release,78),(.motion,94)
            ] {
                let parameter = try XCTUnwrap(StudioAdditiveParameter.harmonic(
                    i, control: control))
                XCTAssertEqual(parameter.rawValue,base+Int32(i))
                XCTAssertEqual(parameter.harmonicShape?.index, i)
                XCTAssertEqual(parameter.harmonicShape?.control, control)
                XCTAssertTrue(parameter.valid(parameter.defaultValue))
                XCTAssertEqual(parameter.value(at: parameter.position(
                    for: parameter.defaultValue)),parameter.defaultValue,
                    accuracy:0.0005)
            }
        }
        XCTAssertNil(StudioAdditiveParameter.harmonic(16,control:.attack))
        XCTAssertTrue(StudioAdditiveParameter.motionDepth.valid(1))
        XCTAssertFalse(StudioAdditiveParameter.motionDepth.valid(1.1))
        XCTAssertFalse(StudioAdditiveParameter.motionRate.valid(13))
        XCTAssertTrue(StudioAdditiveParameter.motionRate.valid(0.02))
        let envelope = try XCTUnwrap(StudioAdditiveParameter.harmonic(
            8,control:.attack))
        XCTAssertFalse(envelope.valid(-1))
        XCTAssertFalse(envelope.valid(.nan))
    }

    func testAnimatedSpectraPersistAndShareMIDIAndModulation() throws {
        var patch = StudioSynthPatch.individual(.additive)
        let id = try XCTUnwrap(patch.layers.first?.id)
        let shape = try XCTUnwrap(StudioAdditiveParameter.harmonic(
            6,control:.release))
        var sound = StudioAdditivePatch()
        sound.set(1,for:.partialEnvelopeMix)
        sound.set(0.64,for:.motionDepth)
        sound.set(1.8,for:.motionRate)
        sound.set(0.4,for:.motionShape)
        sound.set(2.2,for:shape)
        patch.layers[0].additivePatch = sound
        patch.midiControls = StudioSynthMIDIControlSettings(mappings: [
            StudioSynthMIDIControlMapping(controller:74,target:.parameter(
                layerID:id,destination:.additive(.motionDepth)))
        ])
        var modulation = StudioSynthModulationSettings()
        modulation.routes = [
            StudioSynthModRoute(source:.lfo1,layerID:id,
                                destination:.additive(.motionRate),depth:0.15)
        ]
        patch.modulation = modulation
        XCTAssertTrue(patch.validate())
        let encoded = try JSONEncoder().encode(patch)
        let reloaded = try JSONDecoder().decode(StudioSynthPatch.self,from:encoded)
        XCTAssertEqual(reloaded,patch)
        let instrument = try StudioSynthInstrument(sampleRate:44_100,patch:patch)
        XCTAssertEqual(instrument.effectiveParameter(id:id,
                         destination:.additive(shape))!,2.2,accuracy:0.001)
        XCTAssertTrue(instrument.controller(74,value:127))
        var achieved = false
        for _ in 0..<100 {
            if let current = instrument.effectiveParameter(
                id:id,destination:.additive(.motionDepth)),
                abs(current-1)<0.005 {
                achieved = true
                break
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        XCTAssertTrue(achieved,"MIDI Learn must sweep spectral motion depth")
        XCTAssertTrue(instrument.noteOn(67,velocity:106))
        XCTAssertTrue(instrument.noteOff(67))
        XCTAssertTrue(instrument.allNotesOff())
    }

    func testOriginalFactoryPatchesStayClassicUnlessExplicitlyEnhanced() {
        let presets=StudioAdditiveFactoryLibrary.presets
        let animated=presets.filter {
            $0.patch.value(for:.partialEnvelopeMix)>0 &&
            $0.patch.value(for:.motionDepth)>0
        }
        XCTAssertEqual(animated.count,6)
        XCTAssertTrue(presets.first {
            $0.name=="Pure Foundation"
        }!.patch.value(for:.motionDepth)==0)
        for preset in presets {
            XCTAssertTrue(preset.patch.validate(),preset.name)
        }
    }

    func testFourEngineHybridCanRouteMIDIAndLiveAdditiveControls() throws {
        var patch = StudioSynthPatch()
        patch.layers.append(StudioSynthLayer(engine: .wavetable))
        patch.layers.append(StudioSynthLayer(engine: .additive))
        XCTAssertTrue(patch.validate())
        let instrument = try StudioSynthInstrument(sampleRate: 44_100,patch: patch)
        XCTAssertEqual(instrument.auxiliaryNodes.count,8)
        let id = patch.layers[3].id
        XCTAssertTrue(instrument.setAdditiveParameter(
            id: id,parameter: .partial5,value: 0.72))
        XCTAssertEqual(instrument.effectiveParameter(
            id: id,destination: .additive(.partial5))!,0.72,accuracy: 0.001)
        XCTAssertTrue(instrument.noteOn(60,velocity: 112))
        XCTAssertTrue(instrument.noteOff(60))
        XCTAssertTrue(instrument.allNotesOff())
    }
}
