import XCTest
@testable import StudioCloudAuth

@MainActor
final class StudioLocalAuthTests: XCTestCase {
    #if STUDIO_LOCAL_AUTH
    func testStandardBuildCannotAuthenticate() async {
        let service = SupabaseAuthService.shared
        XCTAssertFalse(service.isConfigured)
        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUser)
        service.configure(url: "https://example.invalid", anonKey: "fake")
        XCTAssertFalse(service.isConfigured)
        do {
            try await service.signIn(email: "test@example.invalid", password: "test")
            XCTFail("Local Studio must not authenticate")
        } catch let error as AuthError {
            guard case .notConfigured = error else {
                XCTFail("Expected auth unavailable error")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    #endif
}
