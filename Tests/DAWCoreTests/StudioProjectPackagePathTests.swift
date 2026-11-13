import Foundation
import XCTest
@testable import DAWCore

final class StudioProjectPackagePathTests: XCTestCase {
    func testValidAudioReferenceStaysInsideProjectPackage() throws {
        let package = URL(fileURLWithPath: "/tmp/Orchestra.dawproj", isDirectory: true)
        let url = try XCTUnwrap(StudioProjectPackagePaths.packagedAudioURL(
            relativePath: "Audio Files/recording.wav", inside: package
        ))
        XCTAssertEqual(url.path, "/tmp/Orchestra.dawproj/Audio Files/recording.wav")
    }

    func testTraversalAndAbsolutePathRejected() {
        let package = URL(fileURLWithPath: "/tmp/Orchestra.dawproj", isDirectory: true)
        for path in [
            "", "recording.wav", "../escape.wav", "/etc/passwd",
            "Audio Files/../project.json", "Audio Files//evil.wav",
            "Audio Files/../../escape.wav", "Audio Files/./recording.wav",
            "Audio Files/dir\\recording.wav"
        ] {
            XCTAssertNil(StudioProjectPackagePaths.packagedAudioURL(
                relativePath: path, inside: package
            ), "Expected rejection of \(path)")
        }
    }

    func testSymlinkToOutsideAudioDirectoryIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioPaths-\(UUID())", isDirectory: true)
        let package = root.appendingPathComponent("Orchestra.dawproj", isDirectory: true)
        let audioFolder = package.appendingPathComponent("Audio Files", isDirectory: true)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("secret.wav")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: audioFolder.appendingPathComponent("alias.wav"),
            withDestinationURL: outside
        )
        XCTAssertNil(StudioProjectPackagePaths.packagedAudioURL(
            relativePath: "Audio Files/alias.wav", inside: package
        ))
    }
}
