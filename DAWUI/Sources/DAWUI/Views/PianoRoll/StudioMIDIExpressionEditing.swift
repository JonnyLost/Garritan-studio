import Foundation
import DAWCore

/// A point in the arrangement's absolute quarter-note-beat time domain.
struct StudioMIDIExpressionPoint {
    let beat: Double
    let value: Double // normalized 0...1; 0.5 is centered pitch bend
}

/// MIDI-expression edits are computed from the original MIDI clip every time.
/// The UI previews those edits but registers one undo action at gesture end.
enum StudioMIDIExpressionEditing {
    static func normalizedValue(of event: MIDIEvent, for lane: CCType,
                                channel: UInt8? = nil) -> Double? {
        if let channel, event.channel != channel { return nil }
        switch event.type {
        case .controlChange(let controller, let value)
            where lane != .pitchBend && Int(controller) == lane.rawValue:
            return Double(value) / 127.0
        case .pitchBend(let value) where lane == .pitchBend:
            return Double(max(-8192, min(8191, Int(value))) + 8192) / 16383.0
        default:
            return nil
        }
    }

    static func makeEvent(at beat: Double, lane: CCType, normalized: Double,
                          channel: UInt8 = 0) -> MIDIEvent? {
        guard beat.isFinite, beat >= 0, normalized.isFinite else { return nil }
        let fraction = max(0, min(1, normalized))
        if lane == .pitchBend {
            let value = Int16(Int((fraction * 16383).rounded()) - 8192)
            return MIDIEvent.pitchBend(at: beat, value: value, channel: channel)
        }
        guard lane.rawValue >= 0 && lane.rawValue < 128 else { return nil }
        let v: UInt8
        if lane == .sustain || lane == .sostenuto || lane == .soft {
            v = fraction >= 0.5 ? 127 : 0
        } else {
            v = UInt8(max(0, min(127, Int((fraction * 127).rounded()))))
        }
        return MIDIEvent.controlChange(at: beat, controller: UInt8(lane.rawValue),
                                       value: v, channel: channel)
    }

    /// Add or overwrite a continuous pencil stroke. Only events of the chosen
    /// controller and channel within the stroke are replaced; notes, other
    /// controllers and other channels are retained untouched.
    ///
    /// Snap is anchored to the project beat grid, not the start of a region.
    /// For Snap Off, the caller should use a small finite subdivision (1/32).
    static func draw(events: [MIDIEvent], lane: CCType,
                     points: [StudioMIDIExpressionPoint], clipStartBeat: Double,
                     division: Double, channel: UInt8 = 0) -> [MIDIEvent] {
        guard clipStartBeat.isFinite, clipStartBeat >= 0,
              division.isFinite, division > 0, channel < 16 else { return events }
        let valid = points.filter { $0.beat.isFinite && $0.value.isFinite &&
            $0.beat >= clipStartBeat && $0.beat < 1_000_000 }
        guard !valid.isEmpty else { return events }

        // The grid index bounds keep accidental offscreen mouse gestures
        // from allocating an unbounded MIDI-event collection.
        func index(_ beat: Double) -> Int {
            Int(min(4_000_000, max(0, (beat / division).rounded())))
        }
        var sampled: [Int: Double] = [:]
        let sampleCap = 4096
        func insertPoint(_ a: StudioMIDIExpressionPoint,
                         _ b: StudioMIDIExpressionPoint) {
            let first = index(a.beat)
            let last = index(b.beat)
            let count = abs(last - first)
            guard count <= sampleCap else {
                sampled[first] = a.value
                sampled[last] = b.value
                return
            }
            let strideValue = first <= last ? 1 : -1
            for i in stride(from: first, through: last, by: strideValue) {
                let t = first == last ? 1.0 : Double(i - first) / Double(last - first)
                sampled[i] = a.value + (b.value - a.value) * t
            }
        }
        if let first = valid.first {
            insertPoint(first, first)
        }
        if valid.count > 1 {
            for i in 1..<valid.count {
                insertPoint(valid[i - 1], valid[i])
            }
        }
        guard !sampled.isEmpty else { return events }
        let bounds = sampled.keys.min()!...sampled.keys.max()!
        let tolerance = division * 0.001

        // Keep event IDs at overwritten grid locations where possible.
        var existing: [Int: UUID] = [:]
        for event in events where normalizedValue(of: event, for: lane,
                                                  channel: channel) != nil {
            let absolute = event.beatPosition + clipStartBeat
            let key = index(absolute)
            if bounds.contains(key) && abs(absolute - Double(key) * division) <= tolerance {
                existing[key] = event.id
            }
        }
        var result = events.filter { event in
            guard normalizedValue(of: event, for: lane, channel: channel) != nil else {
                return true
            }
            let absolute = event.beatPosition + clipStartBeat
            return !(absolute >= Double(bounds.lowerBound) * division - tolerance &&
                     absolute <= Double(bounds.upperBound) * division + tolerance)
        }
        for (key, value) in sampled.sorted(by: { $0.key < $1.key }) {
            let beat = max(clipStartBeat, Double(key) * division) - clipStartBeat
            guard var event = makeEvent(at: beat, lane: lane, normalized: value,
                                        channel: channel) else { continue }
            if let id = existing[key] { event.id = id }
            result.append(event)
        }
        return result
    }
}
