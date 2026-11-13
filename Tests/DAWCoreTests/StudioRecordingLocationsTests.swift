import Foundation
import XCTest
@testable import DAWCore

final class StudioRecordingLocationsTests: XCTestCase {
    func testNativeStorageIsPreferredAndOldFilesRemainReachable() {
        let base = URL(fileURLWithPath: "/tmp/studio-app-support", isDirectory: true)
        let candidates = StudioRecordingLocations.recoveryURLs(
            forFilename: "take.wav", inApplicationSupport: base
        )
        XCTAssertEqual(candidates.map(\.path), [
            "/tmp/studio-app-support/Studio/Recordings/take.wav",
            "/tmp/studio-app-support/MusioCreate/Recordings/take.wav"
        ])
    }

    func testUntrustedFilenameCannotTraverseStorage() {
        let base = URL(fileURLWithPath: "/tmp/studio-app-support", isDirectory: true)
        for name in ["", ".", "..", "../secret.wav", "/tmp/secret.wav", "dir\\\\secret.wav"] {
            XCTAssertTrue(
                StudioRecordingLocations.recoveryURLs(
                    forFilename: name, inApplicationSupport: base
                ).isEmpty,
                "Unexpected recovery candidate for \(name)"
            )
        }
    }
}
