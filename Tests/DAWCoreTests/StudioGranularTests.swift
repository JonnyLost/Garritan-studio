import XCTest
import Foundation
import AVFoundation
@testable import DAWCore

@MainActor
final class StudioGranularTests: XCTestCase {
    func testFactoryPresetsAreDistinctValidAndSelfContained() throws {
        let presets=StudioGranularFactoryLibrary.presets
        XCTAssertEqual(presets.count,12)
        XCTAssertEqual(Set(presets.map(\.id)).count,presets.count)
        XCTAssertEqual(Set(presets.map(\.family)),
                       Set(["Pads","Textures","Keys","Leads","Bass"]))
        let encoded=try presets.map{ try JSONEncoder().encode($0.patch) }
        XCTAssertEqual(Set(encoded).count,presets.count)
        for preset in presets {
            XCTAssertTrue(preset.patch.validate(),preset.name)
            XCTAssertNil(preset.patch.importedAudioPath)
            for parameter in StudioGranularParameter.allCases {
                let v=preset.patch.value(for:parameter)
                XCTAssertTrue(parameter.valid(v),preset.name+" "+parameter.name)
            }
        }
    }

    func testSourceAndControlsSurviveProjectJSONRoundTrip() throws {
        var patch=StudioSynthPatch.individual(.granular)
        var sound=StudioGranularPatch()
        sound.source = .bells
        sound.set(0.23,for:.grainSize)
        sound.set(44,for:.density)
        sound.set(0.87,for:.reverse)
        patch.layers[0].granularPatch=sound
        let layerID=patch.layers[0].id
        patch.midiControls=StudioSynthMIDIControlSettings(mappings:[
            StudioSynthMIDIControlMapping(controller:74,target:.parameter(
                layerID:layerID,destination:.granular(.position)))
        ])
        var modulation=StudioSynthModulationSettings()
        modulation.routes=[
            StudioSynthModRoute(source:.lfo1,layerID:layerID,
                                destination:.granular(.scanSpeed),depth:0.13)
        ]
        patch.modulation=modulation
        XCTAssertTrue(patch.validate())
        let data=try JSONEncoder().encode(patch)
        XCTAssertEqual(try JSONDecoder().decode(StudioSynthPatch.self,from:data),
                       patch)
        var invalid=sound
        invalid.values[String(StudioGranularParameter.density.rawValue)]=120
        patch.layers[0].granularPatch=invalid
        XCTAssertFalse(patch.validate())
    }

    func testGranularProducesAudioAndReleasesAllNotesOffline() throws {
        let sampleRate=44_100.0
        let sound=StudioGranularPatch()
        let instrument=try StudioGranularInstrument(
            sampleRate:sampleRate,patch:sound)
        XCTAssertEqual(instrument.sourceFrameCount,32768)
        let engine=AVAudioEngine()
        engine.attach(instrument.audioNode)
        let format=try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate:sampleRate,channels:2))
        engine.connect(instrument.audioNode,to:engine.mainMixerNode,
                       format:format)
        try engine.enableManualRenderingMode(.offline,format:format,
                                             maximumFrameCount:512)
        try engine.start()
        defer {engine.stop();engine.disableManualRenderingMode()}
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat:format,frameCapacity:512))
        XCTAssertTrue(instrument.noteOn(60,velocity:110))
        var maximum:Float=0
        for _ in 0..<20 {
            XCTAssertEqual(try engine.renderOffline(512,to:buffer),.success)
            let data=try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                maximum=max(maximum,abs(data[0][i]),abs(data[1][i]))
                XCTAssertTrue(data[0][i].isFinite)
            }
        }
        XCTAssertGreaterThan(maximum,0.004)
        XCTAssertTrue(instrument.noteOff(60))
        for _ in 0..<100 {
            XCTAssertEqual(try engine.renderOffline(512,to:buffer),.success)
        }
        let data=try XCTUnwrap(buffer.floatChannelData)
        var tail:Float=0
        for i in 0..<Int(buffer.frameLength) {
            tail=max(tail,abs(data[0][i]),abs(data[1][i]))
        }
        XCTAssertLessThan(tail,0.0001)
    }

    func testImportedAudioDecodesOnlyBeforeSourceNodeIsRunning() throws {
        let format=try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate:44_100,channels:2))
        let path=FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        defer {try? FileManager.default.removeItem(at:path)}
        do {
            let output=try AVAudioFile(forWriting:path,settings:format.settings)
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat:format,frameCapacity:4096))
            buffer.frameLength=4096
            let samples=try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<4096 {
                let sample=Float(0.5*sin(Double(i)*440*2*Double.pi/44_100))
                samples[0][i]=sample
                samples[1][i]=sample
            }
            try output.write(from:buffer)
        }
        var patch=StudioGranularPatch()
        patch.importedAudioPath=path.path
        let instrument=try StudioGranularInstrument(sampleRate:44_100,patch:patch)
        XCTAssertEqual(instrument.sourceFrameCount,4096)
        XCTAssertTrue(instrument.noteOn(60,velocity:120))
        XCTAssertTrue(instrument.allNotesOff())
        patch.importedAudioPath=path.path+"-missing"
        XCTAssertThrowsError(try StudioGranularInstrument(sampleRate:44_100,
                                                          patch:patch))
    }

    func testGranularLayersWithOtherSynthesisAndMIDIControls() throws {
        var patch=StudioSynthPatch()
        patch.layers.append(StudioSynthLayer(engine:.granular))
        XCTAssertTrue(patch.validate())
        let granularID=patch.layers[2].id
        let instrument=try StudioSynthInstrument(sampleRate:44_100,patch:patch)
        XCTAssertEqual(instrument.auxiliaryNodes.count,6)
        XCTAssertTrue(instrument.setGranularParameter(
            id:granularID,parameter:.density,value:39))
        XCTAssertEqual(instrument.effectiveParameter(
            id:granularID,destination:.granular(.density))!,
            39,accuracy:0.001)
        XCTAssertTrue(instrument.noteOn(65,velocity:107))
        XCTAssertTrue(instrument.noteOff(65))
        XCTAssertTrue(instrument.allNotesOff())
        XCTAssertTrue(instrument.setMIDIControls(
            StudioSynthMIDIControlSettings(mappings:[
                StudioSynthMIDIControlMapping(
                    controller:74,target:.parameter(
                        layerID:granularID,destination:.granular(.position)))
            ])))
        XCTAssertTrue(instrument.controller(74,value:127))
    }
}
