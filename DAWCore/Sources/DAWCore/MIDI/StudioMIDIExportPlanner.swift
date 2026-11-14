import Foundation

/// MIDI files are portable, but a Standard MIDI File has no native concept of
/// Studio's semantic per-note articulation IDs. Keep a musical-only export
/// safe by default; bake instrument-specific triggers only on explicit opt-in.
public enum StudioMIDIExportMode: String, Codable, Sendable {
    case musicalOnly
    case renderedPerformance
}

/// A time-ordered, file-ready MIDI message. `bytes` contains the MIDI status
/// and data bytes (or a length-prefixed F0 SysEx event), without delta-time.
/// The writer owns track chunks, metadata and delta-time encoding.
public struct StudioMIDIExportMessage: Sendable, Equatable {
    public let tick: Int
    public let bytes: [UInt8]
    public let generatedArticulation: Bool

    public init(tick: Int, bytes: [UInt8], generatedArticulation: Bool) {
        self.tick = tick
        self.bytes = bytes
        self.generatedArticulation = generatedArticulation
    }
}

public enum StudioMIDIExportPlanningError: Error, Equatable, LocalizedError {
    case invalidTempo
    case invalidClipRange
    case invalidEvent
    case invalidMIDIData
    case invalidNoteDuration
    case positionOutOfRange
    case loopedRegionRequiresConsolidation

    public var errorDescription: String? {
        switch self {
        case .invalidTempo:
            return "MIDI export needs a finite, positive project tempo."
        case .invalidClipRange:
            return "A MIDI region has invalid or reversed start/end positions."
        case .invalidEvent:
            return "A MIDI event has an invalid position or channel."
        case .invalidMIDIData:
            return "A MIDI event contains a value outside the MIDI file format."
        case .invalidNoteDuration:
            return "A MIDI note has an invalid duration."
        case .positionOutOfRange:
            return "A MIDI event is outside the Standard MIDI File tick range."
        case .loopedRegionRequiresConsolidation:
            return "Consolidate looped MIDI regions before exporting a MIDI file."
        }
    }
}

/// Pure, offline adaptation of the *same* articulation and trim model used by
/// live playback. No note, map or project object is modified and no realtime
/// audio/MIDI callbacks are touched. This adapter is separate from the
/// StandardMIDIFileExporter currently developed on another feature branch.
public enum StudioMIDIExportPlanner {
    public static let ticksPerQuarterNote = 480
    private static let maxTick = 0x0FFF_FFFF

    private struct OrderedMessage {
        let message: StudioMIDIExportMessage
        let priority: Int
        let sequence: Int
    }

    public static func messages(
        for track: Track, tempo: Double,
        mode: StudioMIDIExportMode = .musicalOnly
    ) throws -> [StudioMIDIExportMessage] {
        guard tempo.isFinite, tempo > 0 else {
            throw StudioMIDIExportPlanningError.invalidTempo
        }
        guard !track.isMuted else { return [] }

        // Reject cases that are not representable by the current native file
        // exporter. Never flatten an unexpanded loop or discard invalid data.
        var endTicks: [ClipID: Int] = [:]
        var originalIDs = Set<UUID>()
        for clip in track.clips where !clip.isMuted {
            guard case .midi(let midi) = clip.content else { continue }
            guard !clip.isLooped else {
                throw StudioMIDIExportPlanningError.loopedRegionRequiresConsolidation
            }
            let start = clip.timeRange.start.beats(atTempo: tempo)
            let end = clip.timeRange.end.beats(atTempo: tempo)
            guard start.isFinite, end.isFinite, start >= 0, end > start else {
                throw StudioMIDIExportPlanningError.invalidClipRange
            }
            _ = try tick(for: start)
            endTicks[clip.id] = try tick(for: end)
            for event in midi.events {
                guard event.beatPosition.isFinite, event.channel <= 15 else {
                    throw StudioMIDIExportPlanningError.invalidEvent
                }
                if case .note(let note) = event.type {
                    guard note.duration.isFinite, note.duration >= 0 else {
                        throw StudioMIDIExportPlanningError.invalidNoteDuration
                    }
                }
                originalIDs.insert(event.id)
            }
        }

        // A copy with its map disabled emits only user-authored MIDI. A mapped
        // performance emits ephemeral keyswitches, controllers and program
        // changes, plus any note-channel reassignment. Nothing is baked into
        // the saved clips in either mode.
        var exportTrack = track
        if mode == .musicalOnly {
            exportTrack.articulationMap = nil
        }
        let rendered = StudioMIDISessionPlanner.events(
            for: exportTrack, tempo: tempo, from: 0)

        var ordered: [OrderedMessage] = []
        func append(_ tick: Int, _ priority: Int, _ bytes: [UInt8],
                    generated: Bool) {
            ordered.append(OrderedMessage(
                message: StudioMIDIExportMessage(
                    tick: tick, bytes: bytes,
                    generatedArticulation: generated),
                priority: priority, sequence: ordered.count))
        }
        for entry in rendered {
            guard let clipEndTick = endTicks[entry.clipID] else { continue }
            let event = entry.event
            let startTick = try tick(for: entry.absoluteBeat)
            let channel = event.channel
            guard channel <= 15 else {
                throw StudioMIDIExportPlanningError.invalidEvent
            }
            let generated = !originalIDs.contains(event.id)
            switch event.type {
            case .note(let note):
                let pitch = try dataByte(note.pitch)
                if note.velocity == 0 {
                    append(startTick, 0, [
                        0x80 | channel, pitch, try dataByte(note.releaseVelocity ?? 0)
                    ], generated: generated)
                    continue
                }
                guard note.duration.isFinite, note.duration >= 0 else {
                    throw StudioMIDIExportPlanningError.invalidNoteDuration
                }
                // Quantizing a note beginning just before a clip trim can
                // put its start on the trim tick. Such a note cannot be
                // written inside this region without violating the boundary.
                guard startTick < clipEndTick else {
                    throw StudioMIDIExportPlanningError.positionOutOfRange
                }
                let nominalEnd = try tick(for: entry.absoluteBeat + note.duration)
                let noteOff = max(startTick + 1, min(nominalEnd, clipEndTick))
                guard noteOff <= clipEndTick, noteOff <= maxTick else {
                    throw StudioMIDIExportPlanningError.positionOutOfRange
                }
                append(startTick, generated ? 2 : 3, [
                    0x90 | channel, pitch, try dataByte(note.velocity)
                ], generated: generated)
                // Note-offs sort before all same-tick state changes and
                // note-ons, protecting retriggers at a region boundary.
                append(noteOff, 0, [
                    0x80 | channel, pitch, try dataByte(note.releaseVelocity ?? 0)
                ], generated: generated)
            case .controlChange(let controller, let value):
                append(startTick, 1, [
                    0xB0 | channel, try dataByte(controller), try dataByte(value)
                ], generated: generated)
            case .programChange(let program):
                append(startTick, 1, [
                    0xC0 | channel, try dataByte(program)
                ], generated: generated)
            case .pitchBend(let value):
                guard (-8192...8191).contains(Int(value)) else {
                    throw StudioMIDIExportPlanningError.invalidMIDIData
                }
                let unsigned = UInt16(Int(value) + 8192)
                append(startTick, 1, [
                    0xE0 | channel, UInt8(unsigned & 0x7F),
                    UInt8((unsigned >> 7) & 0x7F)
                ], generated: generated)
            case .aftertouch(let pressure):
                append(startTick, 1, [
                    0xD0 | channel, try dataByte(pressure)
                ], generated: generated)
            case .polyAftertouch(let note, let pressure):
                append(startTick, 1, [
                    0xA0 | channel, try dataByte(note),
                    try dataByte(pressure)
                ], generated: generated)
            case .sysex(let data):
                let raw = Array(data)
                let payload = raw.first == 0xF0 ? Array(raw.dropFirst()) : raw
                guard payload.count <= maxTick else {
                    throw StudioMIDIExportPlanningError.invalidMIDIData
                }
                append(startTick, 1, [0xF0] +
                    variableLength(payload.count) + payload,
                    generated: generated)
            }
        }
        return ordered.sorted {
            if $0.message.tick != $1.message.tick {
                return $0.message.tick < $1.message.tick
            }
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.sequence < $1.sequence
        }.map(\.message)
    }

    private static func tick(for beat: Double) throws -> Int {
        let value = beat * Double(ticksPerQuarterNote)
        guard value.isFinite, value >= 0, value <= Double(maxTick) else {
            throw StudioMIDIExportPlanningError.positionOutOfRange
        }
        return Int(value.rounded())
    }

    private static func dataByte(_ value: UInt8) throws -> UInt8 {
        guard value <= 127 else {
            throw StudioMIDIExportPlanningError.invalidMIDIData
        }
        return value
    }

    private static func variableLength(_ number: Int) -> [UInt8] {
        var remainder = number
        var bytes = [UInt8(remainder & 0x7F)]
        remainder >>= 7
        while remainder > 0 {
            bytes.insert(UInt8((remainder & 0x7F) | 0x80), at: 0)
            remainder >>= 7
        }
        return bytes
    }
}
