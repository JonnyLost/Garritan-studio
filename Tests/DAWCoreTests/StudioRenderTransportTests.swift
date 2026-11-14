import XCTest
import DAWRealtime

/// Atomic transport primitives used by the experimental Core Audio backend.
/// Graph and stream mutations are separately protected by callback drain.
final class StudioRenderTransportTests: XCTestCase {
    func testInitialStateAndSeekWhileStopped() {
        guard let state = daw_render_transport_create() else {
            XCTFail("Native render transport allocation failed"); return
        }
        defer { daw_render_transport_destroy(state) }
        XCTAssertFalse(daw_render_transport_is_playing(state))
        XCTAssertEqual(daw_render_transport_position(state), 0)
        daw_render_transport_set_position(state, 96_000)
        XCTAssertEqual(daw_render_transport_position(state), 96_000)
        XCTAssertFalse(daw_render_transport_is_playing(state))
    }

    func testPlayPauseResumeAndNegativePreroll() {
        guard let state = daw_render_transport_create() else {
            XCTFail("Native render transport allocation failed"); return
        }
        defer { daw_render_transport_destroy(state) }
        daw_render_transport_set_position(state, -24_000)
        daw_render_transport_set_playing(state, true)
        XCTAssertTrue(daw_render_transport_is_playing(state))
        XCTAssertEqual(daw_render_transport_position(state), -24_000)
        daw_render_transport_set_position(state, 0)
        daw_render_transport_set_playing(state, false)
        XCTAssertFalse(daw_render_transport_is_playing(state))
        XCTAssertEqual(daw_render_transport_position(state), 0)
        daw_render_transport_set_playing(state, true)
        XCTAssertTrue(daw_render_transport_is_playing(state))
    }

    func testSnapshotAcrossControlAndObserverThreads() {
        guard let state = daw_render_transport_create() else {
            XCTFail("Native render transport allocation failed"); return
        }
        defer { daw_render_transport_destroy(state) }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for frame in 0..<30_000 {
                daw_render_transport_set_position(state, Int64(frame))
                daw_render_transport_set_playing(state, frame % 2 == 0)
            }
            group.leave()
        }
        var previous: Int64 = 0
        while group.wait(timeout: .now()) == .timedOut {
            let frame = daw_render_transport_position(state)
            XCTAssertGreaterThanOrEqual(frame, previous)
            previous = frame
            _ = daw_render_transport_is_playing(state)
            Thread.sleep(forTimeInterval: 0.00001)
        }
        XCTAssertEqual(daw_render_transport_position(state), 29_999)
    }
}
