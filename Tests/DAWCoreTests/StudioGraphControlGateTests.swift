import XCTest
@testable import DAWCore

/// The control lock is never used by the render callback. Test the control
/// domain independently of an attached Core Audio hardware device.
final class StudioGraphControlGateTests: XCTestCase {
    func testRecursiveControlTransaction() {
        let gate = StudioGraphControlGate()
        var values: [Int] = []
        gate.perform {
            values.append(1)
            gate.perform { values.append(2) }
            values.append(3)
        }
        XCTAssertEqual(values, [1, 2, 3])
    }

    func testSerializesConcurrentControlMutations() {
        let gate = StudioGraphControlGate()
        let queue = DispatchQueue(label: "studio.graph.gate.tests", attributes: .concurrent)
        let group = DispatchGroup()
        var completed = 0
        for _ in 0..<8 {
            group.enter()
            queue.async {
                for _ in 0..<500 {
                    gate.perform {
                        let before = completed
                        completed = before + 1
                    }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertEqual(gate.perform { completed }, 4_000)
    }

    func testThrowReleasesControlOwnership() {
        enum Failure: Error { case expected }
        let gate = StudioGraphControlGate()
        XCTAssertThrowsError(try gate.perform {
            throw Failure.expected
        })
        let result = gate.perform { 42 }
        XCTAssertEqual(result, 42)
    }
}
