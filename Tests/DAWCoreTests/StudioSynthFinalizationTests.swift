import XCTest
import Foundation
@testable import DAWCore

@MainActor
final class StudioSynthFinalizationTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSynthFinalization-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testPresetRenamePreservesIdentityAndSound() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sound = StudioSynthPatch.individual(.physical)
        let saved = try StudioSynthUserPresetLibrary.save(
            name: "Initial Name", patch: sound, in: folder)
        let renamed = try StudioSynthUserPresetLibrary.rename(
            saved, to: "  New Name  ", in: folder)
        XCTAssertEqual(saved.id, renamed.id)
        XCTAssertEqual(renamed.name, "New Name")
        XCTAssertEqual(renamed.patch, sound)
        XCTAssertEqual(renamed.createdAt, saved.createdAt)
        XCTAssertEqual(try StudioSynthUserPresetLibrary.list(
            in: folder).map(\.name), ["New Name"])
        XCTAssertThrowsError(try StudioSynthUserPresetLibrary.rename(
            saved, to: "", in: folder))
    }

    func testImportCreatesIndependentIdentityAndRejectsDuplicateNames() throws {
        let sourceFolder = try temporaryFolder()
        let destinationFolder = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: sourceFolder)
            try? FileManager.default.removeItem(at: destinationFolder)
        }
        let original = StudioSynthPatch.individual(.wavetable)
        let saved = try StudioSynthUserPresetLibrary.save(
            name: "Imported Wavetable", patch: original, in: sourceFolder)
        let url = StudioSynthUserPresetLibrary.fileURL(
            for: saved, in: sourceFolder)
        let imported = try StudioSynthUserPresetLibrary.importPreset(
            from: url, into: destinationFolder)
        XCTAssertNotEqual(saved.id, imported.id)
        XCTAssertEqual(imported.patch, original)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: StudioSynthUserPresetLibrary.fileURL(
                for: imported, in: destinationFolder).path))
        XCTAssertThrowsError(try StudioSynthUserPresetLibrary.importPreset(
            from: url, into: destinationFolder))
        try StudioSynthUserPresetLibrary.delete(
            imported, in: destinationFolder)
        XCTAssertTrue(try StudioSynthUserPresetLibrary.list(
            in: destinationFolder).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testReplacingSoundPrunesOnlyOrphanAutomationLanes() throws {
        var original = StudioSynthPatch.individual(.analog)
        let id = try XCTUnwrap(original.layers.first?.id)
        original.layers.append(StudioSynthLayer(engine: .granular))
        let granularID = try XCTUnwrap(original.layers.last?.id)
        let analog = AutomationLane(
            parameter: .studioSynth(layerID: id,
                                    destination: .analog(.filterCutoff)))
        let granular = AutomationLane(
            parameter: .studioSynth(layerID: granularID,
                                    destination: .granular(.density)))
        let volume = AutomationLane(parameter: .volume)
        let lanes = [volume, analog, granular]
        XCTAssertEqual(StudioSynthAutomationConsistency.reconcile(
            lanes, for: original).count, 3)

        let replacement = StudioSynthPatch.individual(.analog)
        let pruned = StudioSynthAutomationConsistency.reconcile(
            lanes, for: replacement)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned.first?.parameter, .volume)

        // Modifying a layer while preserving its UUID retains the lane.
        var edited = original
        edited.layers[0].gain = 0.3
        let kept = StudioSynthAutomationConsistency.reconcile(
            lanes, for: edited)
        XCTAssertEqual(kept.count, 3)
        edited.layers[0].enabled = false
        let disabled = StudioSynthAutomationConsistency.reconcile(
            lanes, for: edited)
        XCTAssertEqual(disabled.count, 3,
                       "Temporarily disabling a layer must preserve its lanes")
        XCTAssertTrue(disabled.contains { $0.id == analog.id })
    }

    func testGranularMissingRecordingIsReportedBeforeLoadingSound() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = folder.appendingPathComponent("recording.wav")
        var patch = StudioSynthPatch.individual(.granular)
        var grain = StudioGranularPatch()
        grain.importedAudioPath = sample.path
        patch.layers[0].granularPatch = grain
        XCTAssertTrue(patch.validate())
        XCTAssertTrue(StudioSynthAutomationConsistency
            .usesExternalGranularAudio(patch))
        XCTAssertEqual(StudioSynthAutomationConsistency
            .missingGranularSources(in: patch), [sample.path])
        try Data([1, 2, 3]).write(to: sample)
        XCTAssertTrue(StudioSynthAutomationConsistency
            .missingGranularSources(in: patch).isEmpty)
        XCTAssertFalse(StudioSynthAutomationConsistency
            .usesExternalGranularAudio(.individual(.analog)))
    }
}
