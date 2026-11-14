import XCTest
@testable import DAWCore

final class StudioGraphParameterMailboxTests: XCTestCase {
    func testCommandsStayOrderedAndPreserveTrackIdentity() {
        let mailbox = StudioGraphParameterMailbox(capacity: 8)
        let id = TrackID()
        XCTAssertTrue(mailbox.submit(.trackVolume(id, 0.3)))
        XCTAssertTrue(mailbox.submit(.trackPan(id, -0.4)))
        XCTAssertTrue(mailbox.submit(.trackMute(id, true)))
        XCTAssertTrue(mailbox.submit(.masterVolume(0.8)))

        var names: [String] = []
        mailbox.consume(maximum: 2) { command in
            switch command {
            case let .trackVolume(track, amount):
                XCTAssertEqual(track, id)
                XCTAssertEqual(amount, 0.3)
                names.append("gain")
            case let .trackPan(track, amount):
                XCTAssertEqual(track, id)
                XCTAssertEqual(amount, -0.4)
                names.append("pan")
            default: XCTFail("Incorrect initial command order")
            }
        }
        XCTAssertEqual(names, ["gain", "pan"])
        XCTAssertEqual(mailbox.pendingCount, 2)
        mailbox.consume { command in
            switch command {
            case let .trackMute(track, muted):
                XCTAssertEqual(track, id)
                XCTAssertTrue(muted)
                names.append("mute")
            case let .masterVolume(amount):
                XCTAssertEqual(amount, 0.8)
                names.append("master")
            default: XCTFail("Incorrect remaining command order")
            }
        }
        XCTAssertEqual(names, ["gain", "pan", "mute", "master"])
        XCTAssertEqual(mailbox.pendingCount, 0)
    }

    func testBoundedQueueRejectsOverflowAndRecoversAfterConsume() {
        let mailbox = StudioGraphParameterMailbox(capacity: 4)
        for n in 0..<3 {
            XCTAssertTrue(mailbox.submit(.masterVolume(Float(n))))
        }
        XCTAssertFalse(mailbox.submit(.masterVolume(99)))
        var received: [Float] = []
        mailbox.consume { command in
            if case let .masterVolume(value) = command {
                received.append(value)
            }
        }
        XCTAssertEqual(received, [0, 1, 2])
        XCTAssertTrue(mailbox.submit(.masterVolume(42)))
        mailbox.consume { command in
            if case let .masterVolume(value) = command {
                received.append(value)
            }
        }
        XCTAssertEqual(received, [0, 1, 2, 42])
    }

    func testRenderBudgetAndRepeatedWraparound() {
        let mailbox = StudioGraphParameterMailbox(capacity: 4)
        var observed = 0
        for n in 0..<1000 {
            XCTAssertTrue(mailbox.submit(.masterVolume(Float(n))))
            mailbox.consume(maximum: 0) { _ in XCTFail("Zero budget consumed") }
            XCTAssertEqual(mailbox.pendingCount, 1)
            mailbox.consume(maximum: 1) { _ in observed += 1 }
        }
        XCTAssertEqual(observed, 1000)
        XCTAssertEqual(mailbox.pendingCount, 0)
    }
}
