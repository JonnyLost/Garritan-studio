import XCTest
@testable import DAWCore

final class StudioMIDIWorkerSchedulerTests: XCTestCase {
    private let rack = StudioMIDIDestination.rack(UUID())
    private func event(_ frame: Int64, _ status: UInt8 = 0x90, _ d1: UInt8 = 60,
                       _ d2: UInt8 = 100, destination: StudioMIDIDestination? = nil) -> StudioMIDIFrameEvent {
        StudioMIDIFrameEvent(frame: frame, destination: destination ?? rack,
                            status: status, data1: d1, data2: d2)
    }
    private func entry(_ beat: Double, _ type: MIDIEventType) -> StudioMIDISessionEvent {
        let clip = Clip(name: "Timing", timeRange: TimeRange(
            start: TimePosition(beats: 0, tempo: 120), duration: TimePosition(beats: 16, tempo: 120)),
            content: .midi(MIDIClipData(events: [])))
        return StudioMIDISessionEvent(clipID: clip.id, absoluteBeat: beat,
                                     event: MIDIEvent(beatPosition: beat, type: type))
    }
    private func compile(_ entry: StudioMIDISessionEvent, until end: Double? = nil) -> [StudioMIDIFrameEvent] {
        StudioMIDIFrameCompiler.messages(entry, destination: rack, tempo: 120, sampleRate: 48_000, until: end)
    }

    func testStableSimultaneousVRackOrdering() {
        let messages = [event(10), event(10, 0xB0, 1, 11), event(10, 0x80),
                        event(10, 0xB0, 11, 99), event(10, 0x90, 61)]
        let ordered = StudioMIDIFrameCompiler.ordered(messages)
        XCTAssertEqual(ordered.map(\.status), [0x80, 0xB0, 0xB0, 0x90, 0x90])
        XCTAssertEqual(ordered.filter { $0.status == 0xB0 }.map(\.data1), [1, 11])
        XCTAssertEqual(ordered.filter { $0.status == 0x90 }.map(\.data1), [60, 61])
    }
    func testExplicitNotePairAndMinimumDuration() {
        let score = compile(entry(2, .note(NoteData(pitch: 60, duration: 0))))
        XCTAssertEqual(score.map(\.frame), [48000, 48001])
        XCTAssertEqual(score.map(\.status), [0x90, 0x80])
    }
    func testLoopCrossingNoteClampedAndLoopEndOnsetExcluded() {
        XCTAssertEqual(compile(entry(3, .note(NoteData(pitch: 60, duration: 10))), until: 4).map(\.frame), [72000, 96000])
        XCTAssertTrue(compile(entry(4, .note(NoteData(pitch: 60))), until: 4).isEmpty)
    }
    func testVelocityZeroIsOnlyAnOff() {
        let score = compile(entry(1, .note(NoteData(pitch: 60, velocity: 0))))
        XCTAssertEqual(score.count, 1)
        XCTAssertTrue(score[0].isNoteOff)
    }
    func testControllerPressureAndProgramBytes() {
        let types: [MIDIEventType] = [.controlChange(controller: 11, value: 99),
            .pitchBend(value: 0), .programChange(program: 7),
            .aftertouch(pressure: 81), .polyAftertouch(note: 60, pressure: 90)]
        let score = types.flatMap { compile(entry(0, $0)) }
        XCTAssertEqual(score.map(\.status), [0xB0, 0xE0, 0xC0, 0xD0, 0xA0])
        XCTAssertEqual(score[1].data1, 0)
        XCTAssertEqual(score[1].data2, 64)
        XCTAssertEqual(score[0].data2, 99)
    }
    func testDestinationChannelOverride() {
        let e = entry(0, .controlChange(controller: 1, value: 100))
        let result = StudioMIDIFrameCompiler.messages(e, destination: rack, channel: 15,
                                                     tempo: 120, sampleRate: 48000)
        XCTAssertEqual(result[0].status, 0xBF)
        XCTAssertEqual(result[0].destination, rack)
    }
    func testStaleGenerationCannotAdvanceNewScore() {
        let scheduler = StudioMIDIWorkerScheduler()
        scheduler.install([event(0)], generation: 4)
        XCTAssertEqual(scheduler.advance(to: 100, generation: 2) { _ in XCTFail("stale event") }, 0)
        XCTAssertEqual(scheduler.cursor, 0)
        XCTAssertEqual(scheduler.advance(to: 100, generation: 4) { _ in }, 1)
    }
    func testCancelCleansNotesAndPedalsEvenAfterClockInvalidation() {
        let scheduler = StudioMIDIWorkerScheduler()
        let clock = StudioMIDITransportClock()
        let generation = clock.begin(at: 0)
        scheduler.install([event(0, 0xB0, 64, 127), event(0), event(1000, 0x80)], generation: generation)
        scheduler.advance(to: 1, generation: generation) { _ in }
        clock.cancel()
        var cleanup: [StudioMIDIFrameEvent] = []
        scheduler.cancel { cleanup.append($0) }
        XCTAssertEqual(cleanup.map(\.status), [0x80, 0xB0, 0xB0, 0xB0])
        XCTAssertEqual(cleanup.map(\.data1), [60, 64, 66, 123])
        XCTAssertTrue(cleanup.allSatisfy { $0.data2 == 0 })
        scheduler.cancel { _ in XCTFail("duplicate cleanup") }
    }
    func testStopRestartAndProjectReplacementUseNewDestinations() {
        let scheduler = StudioMIDIWorkerScheduler()
        scheduler.install([event(0)], generation: 2)
        scheduler.advance(to: 1, generation: 2) { _ in }
        scheduler.cancel { XCTAssertEqual($0.destination, rack) }
        let replacement = StudioMIDIDestination.rack(UUID())
        scheduler.install([event(0, destination: replacement)], generation: 4)
        scheduler.advance(to: 1, generation: 2) { _ in XCTFail("old project") }
        scheduler.advance(to: 1, generation: 4) { XCTAssertEqual($0.destination, replacement) }
    }
    func testRapidRepeatedSeeksAndLoopGenerations() {
        let scheduler = StudioMIDIWorkerScheduler()
        let clock = StudioMIDITransportClock()
        var previous: UInt64 = 0
        for i in 0..<1000 {
            clock.cancel()
            scheduler.cancel { _ in }
            let g = clock.begin(at: Int64(i * 100))
            scheduler.install([event(Int64(i * 100))], generation: g)
            XCTAssertEqual(scheduler.advance(to: .max, generation: previous) { _ in XCTFail("stale seek") }, 0)
            XCTAssertTrue(clock.observe(engineFrame: Int64(i * 1024), frames: 256))
            let snapshot = clock.snapshot()!
            XCTAssertEqual(snapshot.generation, g)
            XCTAssertEqual(scheduler.advance(to: snapshot.endFrame, generation: g) { _ in }, 1)
            previous = g
        }
    }
    func testCancellationBetweenSimultaneousMessages() {
        let scheduler = StudioMIDIWorkerScheduler()
        let clock = StudioMIDITransportClock()
        let g = clock.begin(at: 0)
        scheduler.install([event(0), event(0, 0x90, 61)], generation: g)
        XCTAssertEqual(scheduler.advance(to: 1, generation: g,
            isCurrent: { clock.isCurrent(g) }) { _ in clock.cancel() }, 1)
        var notes: [UInt8] = []
        scheduler.cancel { if $0.isNoteOff { notes.append($0.data1) } }
        XCTAssertEqual(notes, [60])
    }
    func testBudgetSaturationPreservesEveryRelease() {
        let scheduler = StudioMIDIWorkerScheduler()
        let notes = (0..<35000).flatMap { i in [event(Int64(i * 2)), event(Int64(i * 2 + 1), 0x80)] }
        scheduler.install(notes, generation: 2)
        var count = 0
        var offs = 0
        while scheduler.cursor < notes.count {
            let delivered = scheduler.advance(to: .max, generation: 2, budget: 17) {
                count += 1
                if $0.isNoteOff { offs += 1 }
            }
            XCTAssertLessThanOrEqual(delivered, 17)
        }
        XCTAssertEqual(count, 70000)
        XCTAssertEqual(offs, 35000)
    }
    func testExclusiveBoundaryAndLateOff() {
        let scheduler = StudioMIDIWorkerScheduler()
        scheduler.install([event(0), event(256, 0x80)], generation: 2)
        XCTAssertEqual(scheduler.advance(to: 256, generation: 2) { _ in }, 1)
        XCTAssertEqual(scheduler.advance(to: 1000, generation: 2) { XCTAssertTrue($0.isNoteOff) }, 1)
        XCTAssertEqual(scheduler.advance(to: 1000, generation: 2) { _ in }, 0)
    }
    func testRemoveOneDestinationKeepsOtherRackRunning() {
        let scheduler = StudioMIDIWorkerScheduler()
        let other = StudioMIDIDestination.rack(UUID())
        scheduler.install([event(0), event(0, destination: other), event(100), event(100, destination: other)], generation: 2)
        scheduler.advance(to: 1, generation: 2) { _ in }
        scheduler.remove(destination: rack) { XCTAssertEqual($0.destination, rack) }
        XCTAssertEqual(scheduler.advance(to: 101, generation: 2) { XCTAssertEqual($0.destination, other) }, 2)
    }
    func testClockUsesRenderFramesNotPollingOrWallTime() {
        let clock = StudioMIDITransportClock()
        let g = clock.begin(at: 24000)
        XCTAssertEqual(clock.snapshot()?.endFrame, 24000)
        clock.observe(engineFrame: 900000, frames: 128)
        XCTAssertEqual(clock.snapshot()?.endFrame, 24128)
        for _ in 0..<1000 { XCTAssertEqual(clock.snapshot()?.endFrame, 24128) }
        clock.observe(engineFrame: 900512, frames: 128)
        XCTAssertEqual(clock.snapshot()?.endFrame, 24640)
        XCTAssertEqual(clock.snapshot()?.generation, g)
    }
    func testClockCoalescesWithoutCapacityOrNoteLoss() {
        let clock = StudioMIDITransportClock()
        clock.begin(at: 0)
        for i in 0..<100000 { clock.observe(engineFrame: Int64(i * 128), frames: 128) }
        XCTAssertEqual(clock.snapshot()?.endFrame, 12800000)
    }
    func testCancelledClockCannotPublishOldPosition() {
        let clock = StudioMIDITransportClock()
        let old = clock.begin(at: 0)
        clock.observe(engineFrame: 0, frames: 128)
        clock.cancel()
        XCTAssertNil(clock.snapshot())
        XCTAssertFalse(clock.observe(engineFrame: 128, frames: 128))
        let new = clock.begin(at: 96000)
        XCTAssertFalse(clock.isCurrent(old))
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(clock.snapshot()?.endFrame, 96000)
        clock.observe(engineFrame: 256, frames: 64)
        XCTAssertEqual(clock.snapshot()?.endFrame, 96064)
    }
    func testSeekRestoresStateButDoesNotRetriggerCrossingNotes() {
        var track = Track(name: "Seek", type: .instrument)
        let events: [MIDIEvent] = [.controlChange(at: 0, controller: 64, value: 127),
            .controlChange(at: 1, controller: 11, value: 81),
            .note(at: 0, pitch: 60, duration: 8), .note(at: 3, pitch: 62, duration: 4)]
        track.clips = [Clip(name: "Phrase", timeRange: TimeRange(
            start: TimePosition(beats: 0, tempo: 120), duration: TimePosition(beats: 8, tempo: 120)),
            content: .midi(MIDIClipData(events: events)))]
        let entries = StudioMIDISessionPlanner.events(for: track, tempo: 120, from: 2, until: 4)
        let messages = StudioMIDIFrameCompiler.ordered(entries.flatMap { compile($0, until: 4) })
        XCTAssertFalse(messages.contains { $0.status == 0x90 && $0.data1 == 60 })
        XCTAssertTrue(messages.contains { $0.status == 0xB0 && $0.data1 == 64 && $0.data2 == 127 && $0.frame == 48000 })
        XCTAssertTrue(messages.contains { $0.status == 0xB0 && $0.data1 == 11 && $0.data2 == 81 })
        XCTAssertEqual(messages.last?.frame, 96000)
    }
    func testTempoAndRateRecompileDeadline() {
        let e = entry(1, .note(NoteData(pitch: 60, duration: 1)))
        let slow = StudioMIDIFrameCompiler.messages(e, destination: rack, tempo: 60, sampleRate: 48000)
        let fast = StudioMIDIFrameCompiler.messages(e, destination: rack, tempo: 120, sampleRate: 96000)
        XCTAssertEqual(slow.map(\.frame), fast.map(\.frame))
        XCTAssertEqual(slow.map(\.frame), [48000, 96000])
    }
    func testBackwardsDeviceTimestampCancelsWithoutReusingOldAnchor() {
        let clock = StudioMIDITransportClock()
        let g = clock.begin(at: 0)
        clock.observe(engineFrame: 1000, frames: 128)
        clock.observe(engineFrame: 1256, frames: 128)
        XCTAssertFalse(clock.observe(engineFrame: 1100, frames: 128))
        XCTAssertFalse(clock.isCurrent(g))
        XCTAssertNil(clock.snapshot())
        clock.begin(at: 24000)
        XCTAssertTrue(clock.observe(engineFrame: 0, frames: 128))
        XCTAssertEqual(clock.snapshot()?.endFrame, 24128)
    }
    func testNoAllNotesOffDuringNormalUninterruptedPlayback() {
        let scheduler = StudioMIDIWorkerScheduler()
        scheduler.install([event(0), event(100, 0x80)], generation: 2)
        scheduler.advance(to: 101, generation: 2) { XCTAssertNotEqual($0.status & 0xF0, 0xB0) }
    }
}
