import Foundation
import XCTest
import DAWRealtime

/// C11 lifetime contract: the controller owns the opaque snapshot storage;
/// the audio consumer borrows it until end_read. No hardware is required.
final class StudioAtomicRouteExchangeTests: XCTestCase {
    func testPublishReturnsOldSnapshotAndDefersReclamationUntilReaderEnds() {
        let first = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        first.initialize(to: 101)
        second.initialize(to: 202)
        defer {
            first.deinitialize(count: 1)
            second.deinitialize(count: 1)
            first.deallocate()
            second.deallocate()
        }

        guard let exchange = daw_route_exchange_create(UnsafeMutableRawPointer(first)) else {
            XCTFail("Failed to create route exchange")
            return
        }
        defer { daw_route_exchange_destroy(exchange) }

        let borrowed = daw_route_exchange_begin_read(exchange)
        XCTAssertEqual(borrowed, UnsafeMutableRawPointer(first))
        XCTAssertFalse(daw_route_exchange_is_quiescent(exchange))
        let previous = daw_route_exchange_publish(exchange, UnsafeMutableRawPointer(second))
        XCTAssertEqual(previous, UnsafeMutableRawPointer(first))
        XCTAssertEqual(borrowed?.assumingMemoryBound(to: UInt64.self).pointee, 101)
        XCTAssertFalse(daw_route_exchange_is_quiescent(exchange))

        daw_route_exchange_end_read(exchange)
        XCTAssertTrue(daw_route_exchange_is_quiescent(exchange))
        let latest = daw_route_exchange_begin_read(exchange)
        XCTAssertEqual(latest, UnsafeMutableRawPointer(second))
        XCTAssertEqual(latest?.assumingMemoryBound(to: UInt64.self).pointee, 202)
        daw_route_exchange_end_read(exchange)

        XCTAssertEqual(daw_route_exchange_take_current_quiescent(exchange),
                       UnsafeMutableRawPointer(second))
    }

    func testShutdownCannotTakeSnapshotWithAnActiveReader() {
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        memory.initialize(to: 77)
        defer {
            memory.deinitialize(count: 1)
            memory.deallocate()
        }
        guard let exchange = daw_route_exchange_create(UnsafeMutableRawPointer(memory)) else {
            XCTFail("Failed to create route exchange")
            return
        }
        defer { daw_route_exchange_destroy(exchange) }

        _ = daw_route_exchange_begin_read(exchange)
        XCTAssertNil(daw_route_exchange_take_current_quiescent(exchange))
        daw_route_exchange_end_read(exchange)
        XCTAssertEqual(daw_route_exchange_take_current_quiescent(exchange),
                       UnsafeMutableRawPointer(memory))
    }
}
