import Foundation
import XCTest
@testable import DAWCore

final class StudioRepeatedSaveAudioRecoveryTests: XCTestCase {
    func testSavingAgainKeepsPackagedRecordingAfterExternalFileDisappears() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioRepeatSave-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("take.wav")
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00])
        try bytes.write(to: source)

        let url = folder.appendingPathComponent("Orchestra.dawproj")
        let manager = ProjectFileManager()
        var project = Project(name: "First save")
        project.audioFiles.append(AudioFileReference(
            originalPath: source.path, relativePath: "",
            sampleRate: 44_100, channelCount: 2,
            lengthInSamples: 2, bitDepth: 24
        ))
        try await manager.save(project: project, to: url)
        try FileManager.default.removeItem(at: source)

        // Simulates Save on the same in-memory UI document, not a reload.
        project.name = "Second save"
        try await manager.saveQuick(project: project, to: url)

        let restored = try await manager.load(from: url)
        XCTAssertEqual(restored.name, "Second save")
        let packagedSource = try XCTUnwrap(restored.audioFiles.first?.originalPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: packagedSource)), bytes)
    }
}
