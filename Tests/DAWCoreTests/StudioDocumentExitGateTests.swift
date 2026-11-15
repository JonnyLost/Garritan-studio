import XCTest
@testable import DAWCore

final class StudioDocumentExitGateTests: XCTestCase {
    @MainActor func testBusySavePreventsCloseAndQuitWithoutPrompt() async {
        let gate = StudioDocumentExitGate()
        let result = await gate.request(isBusy: true) { XCTFail("Must not prompt during a save"); return true }
        XCTAssertFalse(result)
    }
    @MainActor func testCancelOrFailedSaveKeepsDocumentOpenAndAllowsRetry() async {
        let gate = StudioDocumentExitGate()
        let cancelled = await gate.request(isBusy: false) { false }
        XCTAssertFalse(cancelled)
        let retry = await gate.request(isBusy: false) { true }
        XCTAssertTrue(retry)
    }
    @MainActor func testQuitCannotOverlapPendingClose() async {
        let gate = StudioDocumentExitGate()
        let close = await gate.request(isBusy: false) {
            let quit = await gate.request(isBusy: false) { XCTFail("Duplicate negotiation"); return true }
            XCTAssertFalse(quit)
            return false
        }
        XCTAssertFalse(close)
    }
}
