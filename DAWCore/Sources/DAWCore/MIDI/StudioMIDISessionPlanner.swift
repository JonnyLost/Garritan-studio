import Foundation

/// One event compiled for a transport session. Beat positions are absolute,
/// while MIDIEvent.beatPosition keeps its original clip-relative coordinate.
public struct StudioMIDISessionEvent: Sendable {
    public let clipID: ClipID
    public let absoluteBeat: Double
    public let event: MIDIEvent
    public let restoresState: Bool

    public init(clipID: ClipID, absoluteBeat: Double, event: MIDIEvent,
                restoresState: Bool = false) {
        self.clipID = clipID
        self.absoluteBeat = absoluteBeat
        self.event = event
        self.restoresState = restoresState
    }
}

/// Offline, deterministic MIDI compilation shared by the Core Audio backend,
/// AVAudioEngine/V-Rack worker and standalone sequencer. No allocation or
/// project mutation occurs in the audio render callback.
public enum StudioMIDISessionPlanner {
    private enum StateKey: Hashable {
        case keyswitch(UInt8)
        case controller(UInt8, UInt8)
        case program(UInt8)
        case bend(UInt8)
        case pressure(UInt8)
    }

    /// Build only notes/events that should sound *after* a seek. The latest
    /// earlier keyswitch, CC, program and bend are restored at the new start,
    /// in advance of any note on that same beat. Earlier musical notes are
    /// never retriggered, including notes whose duration crosses the seek.
    public static func events(for track: Track, tempo: Double, from startBeat: Double,
                              until endBeat: Double? = nil) -> [StudioMIDISessionEvent] {
        guard !track.isMuted, tempo.isFinite, tempo > 0,
              startBeat.isFinite, startBeat >= 0 else { return [] }
        let upper = endBeat.flatMap { $0.isFinite && $0 > startBeat ? $0 : nil }
        let timeline = track.clips.enumerated().flatMap { clipOrder, clip -> [(item: StudioMIDISessionEvent, priority: Int, index: Int, clipOrder: Int, key: StateKey?)] in
            guard !clip.isMuted, case .midi(let midi) = clip.content else { return [] }
            let clipStart = clip.timeRange.start.beats(atTempo: tempo)
            let clipEnd = clip.timeRange.end.beats(atTempo: tempo)
            guard clipStart.isFinite, clipEnd.isFinite, clipEnd > clipStart else {
                return []
            }
            let originalIDs = Set(midi.events.map(\.id))
            return StudioArticulationRenderer.events(for: midi, map: track.articulationMap)
                .enumerated().compactMap { index, event in
                    let generated = !originalIDs.contains(event.id)
                    var beat = clipStart + event.beatPosition
                    guard beat.isFinite, beat >= clipStart, beat >= 0,
                          track.acceptsMIDIChannel(event.channel) else {
                        return nil
                    }
                    if beat >= clipEnd {
                        // A held controller must release even when its note
                        // reaches the region boundary. Only ephemeral CC-zero
                        // release events may be clamped; never extend or
                        // retrigger musical notes outside their MIDI region.
                        guard generated,
                              case .controlChange(_, 0) = event.type else {
                            return nil
                        }
                        beat = max(clipStart, clipEnd - 0.000001)
                    }
                    let state: StateKey?
                    let priority: Int
                    switch event.type {
                    case .note(let note):
                        state = generated && note.velocity > 0 ? .keyswitch(event.channel) : nil
                        // Generated keyswitch note-on must precede regular notes.
                        priority = generated ? 0 : (note.velocity == 0 ? -1 : 2)
                    case .controlChange(let cc, let value):
                        // MIDI channel-mode messages (120–127) are commands,
                        // never persistent states to restore on a new session.
                        state = cc < 120 ? .controller(event.channel, cc) : nil
                        priority = generated && value == 0 ? -1 : 0
                    case .programChange:
                        state = .program(event.channel)
                        priority = 0
                    case .pitchBend:
                        state = .bend(event.channel)
                        priority = 0
                    case .aftertouch:
                        state = .pressure(event.channel)
                        priority = 0
                    default:
                        state = nil
                        priority = 1
                    }
                    return (StudioMIDISessionEvent(clipID: clip.id,
                                                  absoluteBeat: beat, event: event),
                            priority, index, clipOrder, state)
                }
        }.sorted {
            if $0.item.absoluteBeat != $1.item.absoluteBeat {
                return $0.item.absoluteBeat < $1.item.absoluteBeat
            }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.clipOrder != $1.clipOrder { return $0.clipOrder < $1.clipOrder }
            return $0.index < $1.index
        }

        // The last MIDI state at each (channel, controller/type) wins. Unlike
        // event IDs, these keys remain stable through project save/load.
        var lastState: [StateKey: (event: StudioMIDISessionEvent, order: Int)] = [:]
        for (index, element) in timeline.enumerated() {
            guard element.item.absoluteBeat < startBeat else { break }
            if let key = element.key { lastState[key] = (element.item, index) }
        }
        let restored = lastState.values.sorted { $0.order < $1.order }.map { state in
            var event = state.event.event
            event.id = UUID()
            // Playback-only keyswitches must not extend their held duration
            // across the new seek location.
            if case .note(var note) = event.type {
                note.duration = 0.01
                event.type = .note(note)
            }
            return StudioMIDISessionEvent(clipID: state.event.clipID,
                                          absoluteBeat: startBeat, event: event,
                                          restoresState: true)
        }
        let future = timeline.lazy.map(\.item).filter { item in
            guard item.absoluteBeat >= startBeat else { return false }
            if let upper { return item.absoluteBeat < upper }
            return true
        }
        return restored + Array(future)
    }
}

/// Shared MIDI ordering rule for events scheduled at one Core Audio frame.
/// Note offs release prior voices before new notes start; switches and CCs
/// otherwise stay in the stable order compiled by the session planner.
public enum StudioMIDITransportOrder {
    public static func priority(status: UInt8, data2: UInt8) -> Int {
        switch status & 0xF0 {
        case 0x80: return -1
        case 0x90: return data2 == 0 ? -1 : 1
        default: return 0
        }
    }
}
