import Foundation
import XCTest
@testable import DAWCore

/// No installed Audio Unit is required: verify that the serialized project
/// retains distinct instances, preset bytes, MIDI and orchestral stage state.
@available(macOS 14.0, *)
final class ProjectSlotPersistenceTests: XCTestCase {
    func testTrackAndVRackPresetIdentitySurvivesSaveQuickSaveAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarritanSlotRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Alpha1.dawproj")
        let manager = ProjectFileManager()

        let aria = PluginIdentifier(
            type: .audioUnitInstrument,
            manufacturer: "Garritan", name: "ARIA Player", uniqueID: "test-aria"
        )
        let reverbEffect = PluginIdentifier(
            type: .audioUnitEffect,
            manufacturer: "Test", name: "Stereo Effect", uniqueID: "test-effect"
        )
        var project = Project(name: "Orchestral Sketch")
        let rackSlot = PluginSlot(pluginID: aria, stateData: Data([0xC1, 0xC2]))
        let rack = RackInstrument(name: "Shared ARIA", pluginSlot: rackSlot)
        project.vRack.addInstrument(rack)

        var savedTrackIDs: [TrackID] = []
        var savedInstrumentIDs: [UUID] = []
        var savedEffectIDs: [UUID] = []
        for index in 0..<2 {
            var track = Track(name: "Section \(index + 1)", type: .instrument)
            let instrument = PluginSlot(
                pluginID: aria, stateData: Data([0x01, UInt8(index + 1)])
            )
            let effect = PluginSlot(
                pluginID: reverbEffect, stateData: Data([0xA0, UInt8(index + 1)])
            )
            track.instrumentSlot = instrument
            track.pluginSlots = [effect]
            track.stageReverbZone = index == 0 ? 0 : 4
            track.stageWetTrim = index == 0 ? 1.0 : 0.65
            track.midiOutput = .rackInstrument(id: rack.id, channel: 2)
            let midi = MIDIClipData(events: [
                .note(at: 0, pitch: UInt8(60 + index), velocity: 90, duration: 1)
            ])
            track.clips = [
                Clip(
                    name: "Phrase \(index + 1)",
                    timeRange: TimeRange(
                        start: TimePosition(samples: 0),
                        duration: TimePosition(beats: 4, tempo: 120)
                    ),
                    content: .midi(midi)
                )
            ]
            project.tracks.append(track)
            savedTrackIDs.append(track.id)
            savedInstrumentIDs.append(instrument.id)
            savedEffectIDs.append(effect.id)
        }

        try await manager.save(project: project, to: url)
        var restored = try await manager.load(from: url)
        XCTAssertEqual(restored.name, "Orchestral Sketch")
        XCTAssertEqual(restored.tracks.count, 2)
        XCTAssertEqual(restored.vRack.instruments.count, 1)
        XCTAssertEqual(restored.vRack.instruments[0].pluginSlot.id, rackSlot.id)
        XCTAssertEqual(restored.vRack.instruments[0].pluginSlot.stateData,
                       Data([0xC1, 0xC2]))

        for index in 0..<2 {
            let track = restored.tracks[index]
            XCTAssertEqual(track.id, savedTrackIDs[index])
            XCTAssertEqual(track.instrumentSlot?.id, savedInstrumentIDs[index])
            XCTAssertEqual(track.instrumentSlot?.pluginID, aria)
            XCTAssertEqual(track.instrumentSlot?.stateData,
                           Data([0x01, UInt8(index + 1)]))
            XCTAssertEqual(track.pluginSlots.count, 1)
            XCTAssertEqual(track.pluginSlots[0].id, savedEffectIDs[index])
            XCTAssertEqual(track.pluginSlots[0].pluginID, reverbEffect)
            XCTAssertEqual(track.pluginSlots[0].stateData,
                           Data([0xA0, UInt8(index + 1)]))
            XCTAssertEqual(track.stageReverbZone, index == 0 ? 0 : 4)
            XCTAssertEqual(track.stageWetTrim ?? 0,
                           index == 0 ? 1.0 : 0.65, accuracy: 0.001)
            if case .rackInstrument(let routedID, let channel) = track.midiOutput {
                XCTAssertEqual(routedID, rack.id)
                XCTAssertEqual(channel, 2)
            } else {
                XCTFail("V-Rack routing not preserved")
            }
            guard case .midi(let clipData) = track.clips.first?.content else {
                XCTFail("MIDI content not preserved")
                continue
            }
            XCTAssertEqual(clipData.noteEvents.count, 1)
        }

        // Quick Save must not wipe state bytes or swap identical ARIA instances.
        restored.name = "Saved Again"
        try await manager.saveQuick(project: restored, to: url)
        let reopened = try await manager.load(from: url)
        XCTAssertEqual(reopened.name, "Saved Again")
        XCTAssertEqual(reopened.tracks[0].instrumentSlot?.id, savedInstrumentIDs[0])
        XCTAssertEqual(reopened.tracks[1].instrumentSlot?.id, savedInstrumentIDs[1])
        XCTAssertEqual(reopened.tracks[0].pluginSlots[0].stateData, Data([0xA0, 0x01]))
        XCTAssertEqual(reopened.tracks[1].pluginSlots[0].stateData, Data([0xA0, 0x02]))
        XCTAssertEqual(reopened.vRack.instruments[0].pluginSlot.stateData,
                       Data([0xC1, 0xC2]))
    }
}
