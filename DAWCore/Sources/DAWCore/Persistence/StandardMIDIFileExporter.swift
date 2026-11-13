import Foundation

/// Writes an interoperable Standard MIDI File (format 1, 480 ticks/quarter).
/// This is an offline serializer: it never touches the audio render graph.
enum StandardMIDIFileExporter {
    private static let ticksPerBeat = 480
    private static let maxTick = 0x0FFF_FFFF

    private struct TimedMessage {
        let tick: Int
        let order: Int
        let sequence: Int
        let bytes: [UInt8]
    }

    static func encode(project: Project) throws -> Data {
        var chunks: [[UInt8]] = []
        chunks.append(try makeTrack(conductorEvents(for: project)))

        for track in project.tracks where !track.isMuted &&
            (track.type == .midi || track.type == .instrument) {
            chunks.append(try makeTrack(musicEvents(for: track, project: project)))
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
        try append(0, 1, timeSignatureMessage(project.timeSignature))
        try append(0, 2, tempoMessage(project.tempo.bpm))

        for change in project.timeSignatureChanges {
            try append(change.beatPosition, 3, timeSignatureMessage(change.timeSignature))
        }
        for change in project.tempoChanges {
            guard change.curveType == .step else {
                throw PersistenceError.invalidFormat(
                    "MIDI export requires step tempo changes; flatten tempo ramps first"
                )
            }
            try append(change.beatPosition, 4, tempoMessage(change.tempo.bpm))
        }
        return events
    }

    private static func musicEvents(for track: Track, project: Project) throws -> [TimedMessage] {
        var events: [TimedMessage] = [
            TimedMessage(tick: 0, order: 0, sequence: 0,
                bytes: meta(0x03, Array(track.name.utf8.prefix(1024))))
        ]
        let bpm = project.tempo.bpm

        for clip in track.clips where !clip.isMuted {
            guard case .midi(let midi) = clip.content else { continue }
            // The existing playback scheduler does not expand looped MIDI clips.
            // Refuse rather than silently exporting a different arrangement.
            guard !clip.isLooped else {
                throw PersistenceError.invalidFormat(
                    "Looped MIDI clips must be consolidated before MIDI export"
                )
            }

            let clipStart = clip.timeRange.start.beats(atTempo: bpm)
            let clipEnd = clip.timeRange.end.beats(atTempo: bpm)
            let clipEndTick = try checkedTick(clipEnd)
            _ = try checkedTick(clipStart)

            for event in midi.events where track.acceptsMIDIChannel(event.channel) {
                let absolute = clipStart + event.beatPosition
                guard absolute.isFinite && event.beatPosition.isFinite else {
                    throw PersistenceError.invalidFormat("Invalid MIDI event beat position")
                }
                guard absolute >= clipStart && absolute < clipEnd else { continue }
                let startTick = try checkedTick(absolute)
                let channel = event.channel & 0x0F

                func append(_ tick: Int, _ order: Int, _ bytes: [UInt8]) {
                    events.append(TimedMessage(tick: tick, order: order,
                        sequence: events.count, bytes: bytes))
                }

                switch event.type {
                case .note(let note):
                    let pitch = try dataByte(note.pitch)
                    if note.velocity == 0 {
                        append(startTick, 1, [0x80 | channel, pitch,
                            try dataByte(note.releaseVelocity ?? 0)])
                    } else {
                        guard note.duration.isFinite && note.duration >= 0 else {
                            throw PersistenceError.invalidFormat("Invalid MIDI note duration")
                        }
                        let endTick = try checkedTick(absolute + note.duration)
                        let releaseTick = max(startTick + 1, min(endTick, clipEndTick))
                        append(startTick, 3, [0x90 | channel, pitch, try dataByte(note.velocity)])
                        append(releaseTick, 1, [0x80 | channel, pitch,
                            try dataByte(note.releaseVelocity ?? 0)])
                    }
                case .controlChange(let controller, let value):
                    append(startTick, 2, [0xB0 | channel,
                        try dataByte(controller), try dataByte(value)])
                case .programChange(let program):
                    append(startTick, 2, [0xC0 | channel, try dataByte(program)])
                case .pitchBend(let value):
                    let bend = UInt16(clamping: Int(value) + 8192)
                    append(startTick, 2, [0xE0 | channel,
                        UInt8(bend & 0x7F), UInt8((bend >> 7) & 0x7F)])
                case .aftertouch(let pressure):
                    append(startTick, 2, [0xD0 | channel, try dataByte(pressure)])
                case .polyAftertouch(let note, let pressure):
                    append(startTick, 2, [0xA0 | channel,
                        try dataByte(note), try dataByte(pressure)])
                case .sysex(let data):
                    let raw = Array(data)
                    let payload = raw.first == 0xF0 ? Array(raw.dropFirst()) : raw
                    guard payload.count <= maxTick else {
                        throw PersistenceError.invalidFormat("SysEx message is too large")
                    }
                    append(startTick, 2, [0xF0] + variableLength(payload.count) + payload)
                }
            }
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

    private static func dataByte(_ value: UInt8) throws -> UInt8 {
        guard value <= 127 else {
            throw PersistenceError.invalidFormat("MIDI data byte is outside 0...127")
        }
        return value
    }

    private static func tempoMessage(_ bpm: Double) -> [UInt8] {
        let microseconds = UInt32((60_000_000.0 / bpm).rounded())
        return meta(0x51, [
            UInt8((microseconds >> 16) & 0xFF),
            UInt8((microseconds >> 8) & 0xFF),
            UInt8(microseconds & 0xFF)
        ])
    }

    private static func timeSignatureMessage(_ signature: TimeSignature) -> [UInt8] {
        // Time signatures are expected to use a power-of-two denominator.
        let denominator = max(1, signature.denominator)
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
