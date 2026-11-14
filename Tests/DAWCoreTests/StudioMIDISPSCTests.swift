import XCTest
@testable import DAWCore

/// Atomic MIDI queue contract for the experimental Core Audio backend.
/// The producer and consumer must each be serialized to one thread.
final class StudioMIDISPSCTests: XCTestCase {
    private func event(_ sample: Int64) -> ScheduledMIDIEvent {
        .noteOn(trackID: TrackID(), samplePosition: sample,
                note: UInt8(sample % 127), velocity: 100)
    }

    func testFIFOAndFullQueueDoesNotOverwriteUnreadEvents() {
        let ring = RingBuffer<ScheduledMIDIEvent>(capacity: 4)
        XCTAssertEqual(ring.availableSpace, 3)
        for i in 0..<3 { XCTAssertTrue(ring.push(event(Int64(i)))) }
        XCTAssertFalse(ring.push(event(99)))
        XCTAssertEqual(ring.count, 3)
        for i in 0..<3 {
            XCTAssertEqual(ring.popAndReturn()?.samplePosition, Int64(i))
        }
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.popAndReturn())
        XCTAssertTrue(ring.push(event(5)))
        XCTAssertEqual(ring.popAndReturn()?.samplePosition, 5)
    }

    func testWraparoundAndQuiescentReset() {
        let ring = MIDIEventRingBuffer(capacity: 4)
        for i in 0..<1000 {
            XCTAssertTrue(ring.schedule(event(Int64(i))))
            XCTAssertEqual(ring.peekIfInRange(
                startSample: Int64(i), endSample: Int64(i + 1)
            )?.samplePosition, Int64(i))
            ring.pop()
        }
        XCTAssertEqual(ring.count, 0)
        ring.schedule(event(400))
        ring.clear()
        XCTAssertTrue(ring.isEmpty)
    }

    func testStaleEventsAreDiscardedWithoutRecursion() {
        let ring = MIDIEventRingBuffer(capacity: 64)
        for i in 0..<32 { XCTAssertTrue(ring.schedule(event(Int64(i)))) }
        XCTAssertNil(ring.peekIfInRange(startSample: 100, endSample: 110))
        XCTAssertTrue(ring.isEmpty)
    }

    func testSequentialProducerConsumerHandoff() {
        let ring = RingBuffer<Int>(capacity: 256)
        let total = 20_000
        let queue = DispatchQueue(label: "studio.test.midi.spsc")
        let finished = expectation(description: "producer completes")
        queue.async {
            for n in 0..<total {
                while !ring.push(n) { Thread.sleep(forTimeInterval: 0.00001) }
            }
            finished.fulfill()
        }
        for n in 0..<total {
            var result: Int?
            while result == nil {
                result = ring.popAndReturn()
                if result == nil { Thread.sleep(forTimeInterval: 0.00001) }
            }
            XCTAssertEqual(result, n)
        }
        wait(for: [finished], timeout: 15)
    }
}
