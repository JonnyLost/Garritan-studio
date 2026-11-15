import XCTest
@testable import DAWCore

final class StudioMIDITimingTests: XCTestCase {
    func testClockTempoAndSampleRate() {
        for rate in [44_100.0, 48_000, 96_000] {
            for tempo in [60.0, 120, 180] {
                let samples = StudioMIDIClockMath.samples(forBeats: 4, tempoBPM: tempo, sampleRate: rate)
                XCTAssertEqual(samples, Int64(240 / tempo * rate))
                XCTAssertEqual(StudioMIDIClockMath.beats(forSamples: samples, tempoBPM: tempo,
                                                        sampleRate: rate), 4, accuracy: 0.0001)
            }
        }
        XCTAssertEqual(StudioMIDIClockMath.samples(forBeats: .nan, tempoBPM: 120, sampleRate: 48_000), 0)
        XCTAssertEqual(StudioMIDIClockMath.samples(forBeats: 1, tempoBPM: 0, sampleRate: 48_000), 0)
        XCTAssertEqual(StudioMIDIClockMath.samples(forBeats: .greatestFiniteMagnitude,
                                                   tempoBPM: 1, sampleRate: 96_000), .max)
        XCTAssertEqual(StudioMIDIClockMath.bufferEnd(startSample: .max - 1, frameCount: 512), .max)
        XCTAssertEqual(StudioMIDIClockMath.offset(eventSample: .max, bufferStart: .min), .max)
    }

    func testAUPacketLengths() {
        for channel in UInt8(0)..<16 {
            XCTAssertEqual(StudioMIDIClockMath.packetLength(status: 0xC0 | channel), 2)
            XCTAssertEqual(StudioMIDIClockMath.packetLength(status: 0xD0 | channel), 2)
            for status in [UInt8(0x80), 0x90, 0xA0, 0xB0, 0xE0] {
                XCTAssertEqual(StudioMIDIClockMath.packetLength(status: status | channel), 3)
            }
        }
    }

    func testAUAdapterPreservesTimestampCableAndBytes() {
        let messages: [(UInt8, [UInt8])] = [
            (0x91, [0x91, 60, 100]), (0xC1, [0xC1, 60]),
            (0xD1, [0xD1, 60]), (0xE1, [0xE1, 60, 100])
        ]
        for (status, expected) in messages {
            var delivered = false
            StudioAUMIDIScheduling.send(status: status, data1: 60, data2: 100,
                                       sampleTime: 1_000_037) { time, cable, length, bytes in
                XCTAssertEqual(time, 1_000_037)
                XCTAssertEqual(cable, 0)
                XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: length)), expected)
                delivered = true
            }
            XCTAssertTrue(delivered)
        }
    }

    // Timestamp harness: compares expected project frames with the scheduler's
    // actual delivery frames. This does not measure acoustic/audio-output timing.
    func testDenseDeliveryFramesOrderingAndNotePairing() {
        let scheduler = MIDIScheduler(capacity: 32768)
        let track = Track(name: "Timing", type: .instrument).id
        var expected: [Int64] = []
        for frame in Int64(0)..<4096 {
            // Explicit same-frame ordering: off, sustain, expression, bend, on.
            let messages: [(UInt8, UInt8, UInt8)] = [
                (0x80, 60, 0), (0xB0, 64, 127), (0xB0, 11, 100),
                (0xE0, 0, 64), (0x90, 60, 100)
            ]
            for (status, d1, d2) in messages {
                scheduler.schedule(ScheduledMIDIEvent(trackID: track, samplePosition: frame,
                    status: status, data1: d1, data2: d2, channel: 0))
                expected.append(frame)
            }
        }
        var actual: [Int64] = []
        var statuses: [UInt8] = []
        for start in stride(from: Int64(0), to: 4096, by: 127) {
            scheduler.processEvents(startSample: start, endSample: start + 127) { event, offset in
                actual.append(start + Int64(offset))
                statuses.append(event.status)
            }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Array(statuses.prefix(5)), [0x80, 0xB0, 0xB0, 0xE0, 0x90])
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testLateNoteOffAndExclusiveBoundary() {
        let scheduler = MIDIScheduler()
        let track = Track(name: "Late release", type: .instrument).id
        scheduler.schedule(.noteOn(trackID: track, samplePosition: 8, note: 60, velocity: 100))
        scheduler.schedule(.noteOff(trackID: track, samplePosition: 9, note: 60))
        scheduler.schedule(.noteOn(trackID: track, samplePosition: 20, note: 60, velocity: 100))
        var frames: [UInt32] = []
        XCTAssertEqual(scheduler.processEvents(startSample: 10, endSample: 20) { _, offset in
            frames.append(offset)
        }, 1)
        XCTAssertEqual(frames, [0])
        XCTAssertEqual(scheduler.processEvents(startSample: 20, endSample: 30) { _, offset in
            XCTAssertEqual(offset, 0)
        }, 1)
        scheduler.clear() // Explicitly quiescent: no producer/consumer running.
        XCTAssertTrue(scheduler.isEmpty)
    }
}
