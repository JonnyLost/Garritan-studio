import Foundation

/// An editable musical pattern, independent of any MIDI clip placed on the timeline.
/// Studio renders this to ordinary MIDI events; it never schedules audio itself.
public enum OstinatoMode: String, Codable, Sendable, CaseIterable {
    case rhythmic
    case melodic
}

public struct OstinatoStep: Codable, Sendable, Hashable {
    /// Zero-based position on the pattern's step grid.
    public var index: Int
    public var pitch: UInt8
    public var velocity: UInt8
    /// Fraction of a step to hold the note, from 0.1 to 1.
    public var gate: Double

    public init(index: Int, pitch: UInt8, velocity: UInt8 = 100, gate: Double = 0.85) {
        self.index = index
        self.pitch = min(127, pitch)
        self.velocity = max(1, min(127, velocity))
        self.gate = gate.isFinite ? min(1, max(0.1, gate)) : 0.85
    }
}

public struct OstinatoLane: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// The row's default pitch; individual steps may evolve independently later.
    public var pitch: UInt8
    public var channel: UInt8
    /// Optional future orchestration destination. V1 renders into the selected track.
    public var targetTrackID: TrackID?
    public var steps: [OstinatoStep]

    public init(
        id: UUID = UUID(),
        name: String,
        pitch: UInt8,
        channel: UInt8 = 0,
        targetTrackID: TrackID? = nil,
        steps: [OstinatoStep] = []
    ) {
        self.id = id
        self.name = name
        self.pitch = min(127, pitch)
        self.channel = min(15, channel)
        self.targetTrackID = targetTrackID
        self.steps = steps
    }

    public mutating func toggleStep(at index: Int) {
        if let existing = steps.firstIndex(where: { $0.index == index }) {
            steps.remove(at: existing)
        } else {
            steps.append(OstinatoStep(index: index, pitch: pitch))
        }
    }

    public mutating func changePitch(to pitch: UInt8) {
        self.pitch = min(127, pitch)
        for index in steps.indices { steps[index].pitch = self.pitch }
    }
}

public struct OstinatoPattern: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: OstinatoMode
    public var bars: Int
    /// Quarter-note beats per bar (6/8 is 3 quarter-note beats).
    public var beatsPerBar: Double
    /// 1 = quarters, 2 = eighths, 4 = sixteenths.
    public var stepsPerBeat: Int
    public var lanes: [OstinatoLane]

    public init(
        id: UUID = UUID(),
        name: String,
        mode: OstinatoMode,
        bars: Int = 1,
        beatsPerBar: Double = 4,
        stepsPerBeat: Int = 4,
        lanes: [OstinatoLane] = []
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.bars = min(32, max(1, bars))
        self.beatsPerBar = beatsPerBar.isFinite ? min(16, max(0.25, beatsPerBar)) : 4
        self.stepsPerBeat = min(8, max(1, stepsPerBeat))
        self.lanes = lanes
    }

    public var stepCount: Int {
        // Round one bar separately, so each bar retains its rhythmic structure.
        let stepsInBar = max(1, Int((min(16, max(0.25, beatsPerBar.isFinite ? beatsPerBar : 4)) *
                                    Double(min(8, max(1, stepsPerBeat)))).rounded()))
        return stepsInBar * min(32, max(1, bars))
    }

    public var durationInBeats: Double {
        Double(stepCount) / Double(min(8, max(1, stepsPerBeat)))
    }

    /// Pure, deterministic conversion. Empty/out-of-range steps emit no notes.
    /// Duplicate step indices within a lane are ignored to prevent stacked note-ons.
    public func midiEvents() -> [MIDIEvent] {
        let division = Double(min(8, max(1, stepsPerBeat)))
        var events: [MIDIEvent] = []
        for lane in lanes {
            var emittedIndices: Set<Int> = []
            for step in lane.steps.sorted(by: { $0.index < $1.index }) {
                guard step.index >= 0 && step.index < stepCount,
                      emittedIndices.insert(step.index).inserted else { continue }
                let gate = step.gate.isFinite ? min(1, max(0.1, step.gate)) : 0.85
                let note = MIDIEvent.note(
                    at: Double(step.index) / division,
                    pitch: step.pitch,
                    velocity: max(1, min(127, step.velocity)),
                    duration: gate / division,
                    channel: min(15, lane.channel)
                )
                events.append(note)
            }
        }
        return events.sorted {
            if $0.beatPosition != $1.beatPosition { return $0.beatPosition < $1.beatPosition }
            return $0.channel < $1.channel
        }
    }

    /// Defaults are musical starting points, not Garritan-specific keyswitch maps.
    public static func starter(mode: OstinatoMode, beatsPerBar: Double = 4) -> OstinatoPattern {
        let rhythmic = mode == .rhythmic
        let names = rhythmic ? ["Low Drum", "Mid Drum", "High Drum"] : ["C4", "E♭4", "G4"]
        let pitches: [UInt8] = rhythmic ? [36, 43, 48] : [60, 63, 67]
        let hits = rhythmic ? [[0, 8], [4, 12], [2, 6, 10, 14]] :
                              [[0, 4, 8, 12], [2, 10], [6, 14]]
        let maxSteps = max(1, Int((beatsPerBar * 4).rounded()))
        let lanes = zip(names.indices, names).map { index, name in
            OstinatoLane(
                name: name,
                pitch: pitches[index],
                steps: hits[index].filter { $0 < maxSteps }
                    .map { OstinatoStep(index: $0, pitch: pitches[index]) }
            )
        }
        return OstinatoPattern(
            name: rhythmic ? "New Rhythm" : "New Motif",
            mode: mode,
            beatsPerBar: beatsPerBar,
            lanes: lanes
        )
    }
}

/// Produces a new, editable MIDI clip without changing any original pattern or track.
public enum OstinatoRenderer {
    public static func makeClip(
        pattern: OstinatoPattern,
        atBeat beat: Double,
        tempo: Double,
        sampleRate: Double
    ) -> Clip? {
        guard beat.isFinite, beat >= 0, tempo.isFinite, tempo > 0,
              sampleRate.isFinite, sampleRate > 0 else { return nil }
        let events = pattern.midiEvents()
        guard !events.isEmpty else { return nil }

        let start = TimePosition(beats: beat, tempo: tempo, sampleRate: sampleRate)
        let duration = TimePosition(beats: pattern.durationInBeats,
                                    tempo: tempo, sampleRate: sampleRate)
        return Clip(
            name: pattern.name,
            timeRange: TimeRange(start: start, duration: duration),
            content: .midi(MIDIClipData(events: events, originalTempo: tempo))
        )
    }
}
