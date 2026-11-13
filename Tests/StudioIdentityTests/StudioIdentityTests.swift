import Foundation
import XCTest
import StudioIdentity

/// Guards the public-facing name without silently changing file associations
/// or the original bundle identity used by existing installations.
final class StudioIdentityTests: XCTestCase {
    func testLegacyIdentifiersRemainStable() {
        XCTAssertEqual(StudioApplicationIdentity.displayName, "Studio")
        XCTAssertEqual(StudioApplicationIdentity.legacyBundleIdentifier, "com.musio.create")
        XCTAssertEqual(StudioApplicationIdentity.legacyProjectTypeIdentifier,
                       "com.musio.create.project")
    }

    func testBundleMetadataMatchesSharedIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = root.appendingPathComponent("DAWApp/Resources/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return XCTFail("App metadata is not a property-list dictionary")
        }
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String,
                       StudioApplicationIdentity.displayName)
        XCTAssertEqual(plist["CFBundleName"] as? String,
                       StudioApplicationIdentity.displayName)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String,
                       StudioApplicationIdentity.legacyBundleIdentifier)

        let types = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let exported = try XCTUnwrap(types.first)
        XCTAssertEqual(exported["UTTypeIdentifier"] as? String,
                       StudioApplicationIdentity.legacyProjectTypeIdentifier)
        let tags = try XCTUnwrap(exported["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try XCTUnwrap(tags["public.filename-extension"] as? [String])
        XCTAssertTrue(extensions.contains("dawproj"))

        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try XCTUnwrap(documents.first)
        let supportedTypes = try XCTUnwrap(document["LSItemContentTypes"] as? [String])
        XCTAssertTrue(supportedTypes.contains(
            StudioApplicationIdentity.legacyProjectTypeIdentifier
        ))
    }
}
