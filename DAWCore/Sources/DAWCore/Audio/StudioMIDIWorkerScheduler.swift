import Foundation
import DAWRealtime

/// Shared by the silent render source and serial MIDI worker. The C mailbox coalesces
/// position observations, never MIDI events. All musical packets stay in the
/// immutable worker score until delivered or explicitly cancelled with cleanup.
final class StudioMIDITransportClock: @unchecked Sendable {
    let storage: OpaquePointer
    init() {
        guard let storage = daw_midi_clock_create() else { fatalError("MIDI clock allocation failed") }
        self.storage = storage
    }
    deinit { daw_midi_clock_destroy(storage) }
    @discardableResult func begin(at frame: Int64) -> UInt64 { daw_midi_clock_begin(storage, frame) }
    func cancel() { daw_midi_clock_cancel(storage) }
    func isCurrent(_ generation: UInt64) -> Bool { daw_midi_clock_is_current(storage, generation) }
    @discardableResult func observe(engineFrame: Int64, frames: UInt32) -> Bool {
        daw_midi_clock_observe(storage, engineFrame, frames)
    }
    func snapshot() -> (generation: UInt64, endFrame: Int64)? {
        var generation: UInt64 = 0
        var frame: Int64 = 0
        return daw_midi_clock_snapshot(storage, &generation, &frame) ? (generation, frame) : nil
    }
}

enum StudioMIDIDestination: Hashable, Sendable {
    case track(TrackID)
    case rack(UUID)
}
struct StudioMIDIFrameEvent: Sendable, Equatable {
    let frame: Int64
    let destination: StudioMIDIDestination
    let status: UInt8
    let data1: UInt8
    let data2: UInt8
    var channel: UInt8 { status & 15 }
    var isNoteOff: Bool { status & 0xF0 == 0x80 || (status & 0xF0 == 0x90 && data2 == 0) }
}

/// Compilation happens on the control thread. MIDI 1.0 bytes and absolute
/// project sample frames are shared across native, AU and V-Rack destinations.
enum StudioMIDIFrameCompiler {
    static func messages(_ entry: StudioMIDISessionEvent, destination: StudioMIDIDestination,
                         channel: UInt8? = nil, tempo: Double, sampleRate: Double,
                         until endBeat: Double? = nil) -> [StudioMIDIFrameEvent] {
        guard entry.absoluteBeat.isFinite, entry.absoluteBeat >= 0,
              tempo.isFinite, tempo > 0, sampleRate.isFinite, sampleRate > 0 else { return [] }
        if let endBeat, entry.absoluteBeat >= endBeat { return [] }
        let ch = (channel ?? entry.event.channel) & 15
        let start = StudioMIDIClockMath.samples(forBeats: entry.absoluteBeat, tempoBPM: tempo, sampleRate: sampleRate)
        func message(_ frame: Int64, _ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> StudioMIDIFrameEvent {
            StudioMIDIFrameEvent(frame: frame, destination: destination, status: status | ch, data1: d1, data2: d2)
        }
        switch entry.event.type {
        case .note(let note):
            guard note.duration.isFinite, note.duration >= 0 else { return [] }
            if note.velocity == 0 { return [message(start, 0x80, note.pitch, 0)] }
            let end = StudioMIDIClockMath.samples(
                forBeats: min(entry.absoluteBeat + note.duration, endBeat ?? .greatestFiniteMagnitude),
                tempoBPM: tempo, sampleRate: sampleRate)
            let next = start == .max ? start : start + 1
            return [message(start, 0x90, note.pitch, note.velocity),
                    message(max(next, end), 0x80, note.pitch, note.releaseVelocity ?? 0)]
        case .controlChange(let cc, let value): return [message(start, 0xB0, cc, value)]
        case .programChange(let program): return [message(start, 0xC0, program, 0)]
        case .pitchBend(let value):
            let bend = UInt16(min(16383, max(0, Int(value) + 8192)))
            return [message(start, 0xE0, UInt8(bend & 127), UInt8((bend >> 7) & 127))]
        case .aftertouch(let value): return [message(start, 0xD0, value, 0)]
        case .polyAftertouch(let note, let value): return [message(start, 0xA0, note, value)]
        case .sysex: return [] // Existing channel-message scope; no SysEx loss claim.
        }
    }
    static func ordered(_ events: [StudioMIDIFrameEvent]) -> [StudioMIDIFrameEvent] {
        events.enumerated().sorted {
            if $0.element.frame != $1.element.frame { return $0.element.frame < $1.element.frame }
            let lp = StudioMIDITransportOrder.priority(status: $0.element.status, data2: $0.element.data2)
            let rp = StudioMIDITransportOrder.priority(status: $1.element.status, data2: $1.element.data2)
            return lp == rp ? $0.offset < $1.offset : lp < rp
        }.map(\.element)
    }
}

/// Owned ONLY by the serial MIDI worker, including install/cancel. No render
/// thread accesses this object. Work per poll is bounded; a budget exhaustion
/// defers packets and NEVER drops a note-off. No fixed-capacity MIDI queue.
final class StudioMIDIWorkerScheduler {
    private(set) var generation: UInt64 = 0
    private(set) var cursor = 0
    private var events: [StudioMIDIFrameEvent] = []
    private var active: Set<Voice> = []
    private var channels: [Channel] = []
    private var targetFrame: Int64 = .min
    private var removed: Set<StudioMIDIDestination> = []
    private struct Channel: Hashable { let destination: StudioMIDIDestination; let channel: UInt8 }
    private struct Voice: Hashable { let channel: Channel; let pitch: UInt8 }
    var isInstalled: Bool { generation != 0 }

    func install(_ events: [StudioMIDIFrameEvent], generation: UInt64) {
        precondition(!isInstalled, "Cancel and clean old voices before replacing a session")
        self.events = events
        self.generation = generation
        cursor = 0
        targetFrame = .min
        var seen: Set<Channel> = []
        channels = events.compactMap { event in
            let key = Channel(destination: event.destination, channel: event.channel)
            return seen.insert(key).inserted ? key : nil
        }
    }
    @discardableResult
    func advance(to endFrame: Int64, generation: UInt64, budget: Int = 2048,
                 isCurrent: () -> Bool = { true }, deliver: (StudioMIDIFrameEvent) -> Void) -> Int {
        guard generation == self.generation, isInstalled else { return 0 }
        targetFrame = max(targetFrame, endFrame)
        var count = 0
        while cursor < events.count, count < max(0, budget),
              events[cursor].frame < targetFrame, isCurrent() {
            let event = events[cursor]
            if removed.contains(event.destination) {
                cursor += 1
                count += 1
                continue
            }
            let key = Voice(channel: Channel(destination: event.destination, channel: event.channel), pitch: event.data1)
            if event.isNoteOff { active.remove(key) }
            else if event.status & 0xF0 == 0x90 { active.insert(key) }
            deliver(event)
            cursor += 1
            count += 1
        }
        return count
    }
    func remove(destination: StudioMIDIDestination, deliver: (StudioMIDIFrameEvent) -> Void) {
        for channel in channels where channel.destination == destination {
            cleanup(channel, deliver: deliver)
        }
        removed.insert(destination)
    }

    private func cleanup(_ channel: Channel, deliver: (StudioMIDIFrameEvent) -> Void) {
        for pitch in active.filter({ $0.channel == channel }).map(\.pitch).sorted() {
            deliver(StudioMIDIFrameEvent(frame: 0, destination: channel.destination,
                status: 0x80 | channel.channel, data1: pitch, data2: 0))
        }
        active = active.filter { $0.channel != channel }
        for cc in [UInt8(64), 66, 123] {
            deliver(StudioMIDIFrameEvent(frame: 0, destination: channel.destination,
                status: 0xB0 | channel.channel, data1: cc, data2: 0))
        }
    }

    /// Runs before replacement routing is published. Clean the OLD destination
    /// snapshot even after its generation is invalid; stale ordinary work is
    /// discarded, but voice/pedal cleanup is deliberately not generation-filtered.
    func cancel(deliver: (StudioMIDIFrameEvent) -> Void) {
        guard isInstalled else { return }
        // Stable score-derived channel order; stable pitch order per channel.
        for channel in channels where !removed.contains(channel.destination) {
            cleanup(channel, deliver: deliver)
        }
        removed.removeAll(keepingCapacity: true)
        active.removeAll(keepingCapacity: true)
        channels.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        generation = 0
        cursor = 0
        targetFrame = .min
    }
}

/// All mutable fields are confined to midiProcessingQueue. Control publishes
/// instrument snapshots only inside that queue's synchronous barriers. The
/// render source never references this object or any instrument registry.
final class StudioMIDIWorkerState: @unchecked Sendable {
    let scheduler = StudioMIDIWorkerScheduler()
    var active = false
    var trackInstruments: [TrackID: TrackInstrument] = [:]
    var rackInstruments: [UUID: TrackInstrument] = [:]
    func send(_ event: StudioMIDIFrameEvent) {
        let instrument: TrackInstrument?
        switch event.destination {
        case .track(let id): instrument = trackInstruments[id]
        case .rack(let id): instrument = rackInstruments[id]
        }
        instrument?.sendWorkerMIDI(event)
    }
}
