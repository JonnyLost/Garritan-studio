import Foundation
import Combine
import DAWCore

/// Main-actor MIDI audition scheduler. It never changes the arrangement or audio graph.
/// Every stop/cancellation releases notes started by this preview session.
@MainActor
final class OstinatoAuditioner: ObservableObject {
    @Published private(set) var isAuditioning = false
    @Published var loops = true

    private var playbackTask: Task<Void, Never>?
    private var session = UUID()
    private var sounding: Set<NoteKey> = []
    private weak var engine: PlaybackEngine?
    private var destinations: [UUID: TrackID] = [:]

    private struct NoteKey: Hashable {
        let track: TrackID
        let pitch: UInt8
        let channel: UInt8
    }
    private struct Event {
        let beat: Double
        let track: TrackID
        let pitch: UInt8
        let velocity: UInt8
        let channel: UInt8
        let isOn: Bool
    }

    func start(pattern: OstinatoPattern, track: TrackID, validTracks: Set<TrackID>, tempo: Double, engine: PlaybackEngine) {
        stop()
        guard tempo.isFinite, tempo > 0, pattern.durationInBeats > 0 else { return }
        let events = Self.events(for: pattern, fallback: track, validTracks: validTracks)
        guard !events.isEmpty else { return }
        self.engine = engine
        destinations = Dictionary(uniqueKeysWithValues: pattern.audibleLanes.map { ($0.id, ($0.targetTrackID.flatMap { validTracks.contains($0) ? $0 : nil }) ?? track) })
        isAuditioning = true
        let token = session
        playbackTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                var previousBeat = 0.0
                for event in events {
                    if Task.isCancelled || token != self.session { return }
                    let seconds = max(0, event.beat - previousBeat) * 60 / tempo
                    if seconds > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    }
                    if Task.isCancelled || token != self.session { return }
                    self.send(event)
                    previousBeat = event.beat
                }
                let remaining = max(0, pattern.durationInBeats - previousBeat) * 60 / tempo
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                if Task.isCancelled || token != self.session { return }
                self.releaseNotes()
            } while self.loops
            self.stop()
        }
    }

    func stop() {
        session = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        releaseNotes()
        isAuditioning = false
        destinations.removeAll()
        engine = nil
    }

    private func send(_ event: Event) {
        let track = event.track
        let key = NoteKey(track: track, pitch: event.pitch, channel: event.channel)
        if event.isOn {
            // Retrigger safely if two lanes share a pitch/channel.
            if sounding.contains(key) {
                engine?.sendOstinatoPreviewNote(pitch: key.pitch, velocity: 0,
                    channel: key.channel, on: track, isNoteOn: false)
            }
            sounding.insert(key)
        } else {
            guard sounding.remove(key) != nil else { return }
        }
        engine?.sendOstinatoPreviewNote(pitch: event.pitch, velocity: event.velocity,
            channel: event.channel, on: track, isNoteOn: event.isOn)
    }

    private func releaseNotes() {
        for key in sounding {
            engine?.sendOstinatoPreviewNote(pitch: key.pitch, velocity: 0,
                channel: key.channel, on: key.track, isNoteOn: false)
        }
        sounding.removeAll()
    }

    private static func events(for pattern: OstinatoPattern, fallback: TrackID,
                               validTracks: Set<TrackID>) -> [Event] {
        var result: [Event] = []
        for routed in pattern.routedMIDIEvents() {
            let track = routed.lane.targetTrackID.flatMap {
                validTracks.contains($0) ? $0 : nil
            } ?? fallback
            for note in routed.events {
                guard case .note(let data) = note.type else { continue }
                result.append(Event(beat: note.beatPosition, track: track, pitch: data.pitch,
                                    velocity: data.velocity, channel: note.channel, isOn: true))
                result.append(Event(beat: note.beatPosition + data.duration, track: track,
                                    pitch: data.pitch, velocity: 0, channel: note.channel, isOn: false))
            }
        }
        return result.sorted {
            if $0.beat != $1.beat { return $0.beat < $1.beat }
            return !$0.isOn && $1.isOn
        }
    }
}
