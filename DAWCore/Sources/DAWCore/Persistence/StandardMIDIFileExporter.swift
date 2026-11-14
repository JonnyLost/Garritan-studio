import Foundation

/// Writes an interoperable Standard MIDI File (format 1, 480 ticks/quarter).
/// This is an offline serializer: it never touches the audio render graph.
/// Adapted from the existing native exporter on feature/studio-core-midi-export;
/// the new MIDI planner handles articulation-safe channel event generation.
enum StandardMIDIFileExporter {
    private static let ticksPerBeat = 480
    private static let maxTick = 0x0FFF_FFFF

    private struct TimedMessage {
        let tick: Int
        let order: Int
        let sequence: Int
        let bytes: [UInt8]
    }

    static func encode(project: Project,
                       mode: StudioMIDIExportMode = .musicalOnly) throws -> Data {
        var chunks: [[UInt8]] = []
        chunks.append(try makeTrack(conductorEvents(for: project)))

        for track in project.tracks where !track.isMuted &&
            (track.type == .midi || track.type == .instrument) {
            chunks.append(try makeTrack(musicEvents(for: track, project: project, mode: mode)))
        }

        guard chunks.count <= Int(UInt16.max) else {
            throw PersistenceError.invalidFormat("Too many MIDI tracks to export")
        }

        var file: [UInt8] = Array("MThd".utf8)
        file += bigEndian32(6)
        file += bigEndian16(1) // Format 1: simultaneous tracks, global conductor track.
        file += bigEndian16(UInt16(chunks.count))
        file += bigEndian16(UInt16(ticksPerBeat))
        for chunk in chunks {
            file += try makeChunk(identifier: "MTrk", payload: chunk)
        }
        return Data(file)
    }

    private static func conductorEvents(for project: Project) throws -> [TimedMessage] {
        var events: [TimedMessage] = []
        func append(_ beat: Double, _ order: Int, _ bytes: [UInt8]) throws {
            let tick = try checkedTick(beat)
            events.append(TimedMessage(tick: tick, order: order,
                sequence: events.count, bytes: bytes))
        }

        try append(0, 0, meta(0x03, Array(project.name.utf8.prefix(1024))))
        try append(0, 1, try timeSignatureMessage(project.timeSignature))
        try append(0, 2, try tempoMessage(project.tempo.bpm))

        for change in project.timeSignatureChanges {
            try append(change.beatPosition, 3, try timeSignatureMessage(change.timeSignature))
        }
        for change in project.tempoChanges {
            guard change.curveType == .step else {
                throw PersistenceError.invalidFormat(
                    "MIDI export requires step tempo changes; flatten tempo ramps first"
                )
            }
            try append(change.beatPosition, 4, try tempoMessage(change.tempo.bpm))
        }
        return events
    }

    /// Keep the existing SMF writer's conductor, track metadata, and atomic
    /// file contract while using the shared arrangement/articulation compiler.
    /// That compiler defines the exact same-tick ordering; do not re-sort
    /// controller messages behind musical notes here.
    private static func musicEvents(
        for track: Track, project: Project, mode: StudioMIDIExportMode
    ) throws -> [TimedMessage] {
        var events = [TimedMessage(
            tick: 0, order: 0, sequence: 0,
            bytes: meta(0x03, Array(track.name.utf8.prefix(1024)))
        )]
        let messages = try StudioMIDIExportPlanner.messages(
            for: track, tempo: project.tempo.bpm, mode: mode
        )
        for message in messages {
            events.append(TimedMessage(
                tick: message.tick, order: 1, sequence: events.count,
                bytes: message.bytes
            ))
        }
        return events
    }

    private static func makeTrack(_ events: [TimedMessage]) throws -> [UInt8] {
        let sorted = events.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.sequence < $1.sequence
        }

        var output: [UInt8] = []
        var previousTick = 0
        for event in sorted {
            let delta = event.tick - previousTick
            guard delta >= 0 && delta <= maxTick else {
                throw PersistenceError.invalidFormat("MIDI event delta exceeds file limit")
            }
            output += variableLength(delta)
            output += event.bytes
            previousTick = event.tick
        }
        output += [0x00, 0xFF, 0x2F, 0x00] // End of track.
        return output
    }

    private static func checkedTick(_ beat: Double) throws -> Int {
        let tick = beat * Double(ticksPerBeat)
        guard tick.isFinite && tick >= 0 && tick <= Double(maxTick) else {
            throw PersistenceError.invalidFormat("MIDI position is outside exportable range")
        }
        return Int(tick.rounded())
    }

    private static func tempoMessage(_ bpm: Double) throws -> [UInt8] {
        guard bpm.isFinite && bpm > 0 else {
            throw PersistenceError.invalidFormat("Tempo must be a finite positive value")
        }
        let rawMicroseconds = (60_000_000.0 / bpm).rounded()
        guard rawMicroseconds >= 1 && rawMicroseconds <= 0xFF_FFFF else {
            throw PersistenceError.invalidFormat("Tempo cannot be represented in MIDI")
        }
        let microseconds = UInt32(rawMicroseconds)
        return meta(0x51, [
            UInt8((microseconds >> 16) & 0xFF),
            UInt8((microseconds >> 8) & 0xFF),
            UInt8(microseconds & 0xFF)
        ])
    }

    private static func timeSignatureMessage(_ signature: TimeSignature) throws -> [UInt8] {
        let denominator = signature.denominator
        guard (1...255).contains(signature.numerator),
              (1...128).contains(denominator),
              (denominator & (denominator - 1)) == 0 else {
            throw PersistenceError.invalidFormat("MIDI time signature requires a valid numerator and power-of-two denominator")
        }
        let exponent = denominator.trailingZeroBitCount
        return meta(0x58, [
            UInt8(clamping: signature.numerator),
            UInt8(clamping: exponent), 24, 8
        ])
    }

    private static func meta(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0xFF, type] + variableLength(payload.count) + payload
    }

    private static func variableLength(_ number: Int) -> [UInt8] {
        var remaining = number
        var bytes = [UInt8(remaining & 0x7F)]
        remaining >>= 7
        while remaining > 0 {
            bytes.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
            remaining >>= 7
        }
        return bytes
    }

    private static func makeChunk(identifier: String, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count <= Int(UInt32.max) else {
            throw PersistenceError.invalidFormat("MIDI track is too large")
        }
        return Array(identifier.utf8) + bigEndian32(UInt32(payload.count)) + payload
    }

    private static func bigEndian16(_ n: UInt16) -> [UInt8] {
        [UInt8(n >> 8), UInt8(n & 0xFF)]
    }

    private static func bigEndian32(_ n: UInt32) -> [UInt8] {
        [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
         UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }
}
