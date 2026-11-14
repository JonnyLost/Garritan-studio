import Foundation

/// Strict, offline Standard MIDI File reader. Supports PPQ-based format 0/1,
/// including running status, tempo/meter metadata and channel performance
/// messages. The result is a *new* Studio project: never mutate the currently
/// loaded project or assume an imported instrument patch is available.
enum StandardMIDIFileImporter {
    private static let maxFileBytes = 64 * 1024 * 1024
    private static let maxTrackCount = 256
    private static let maxEvents = 1_000_000
    private static let maxTick = 0x0FFF_FFFF

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int = 0

        mutating func read(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= bytes.count - offset else {
                throw invalid("Truncated MIDI file")
            }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw invalid("Unexpected end of MIDI file") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func word() throws -> Int {
            let bytes = try read(2)
            return (Int(bytes[0]) << 8) | Int(bytes[1])
        }

        mutating func long() throws -> Int {
            let bytes = try read(4)
            return bytes.reduce(0) { ($0 << 8) | Int($1) }
        }

        mutating func vlq() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                let byte = try self.byte()
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw invalid("MIDI variable-length quantity exceeds four bytes")
        }
    }

    private struct PendingNote {
        let tick: Int
        let sequence: Int
        let velocity: UInt8
    }

    private struct EventEntry {
        let tick: Int
        let sequence: Int
        let event: MIDIEvent
        let endTick: Int
    }

    private struct TimedMeta {
        let tick: Int
        let order: Int
        let tempo: Double?
        let signature: TimeSignature?
    }

    private struct ParsedTrack {
        let name: String?
        let events: [MIDIEvent]
        let maximumTick: Int
        let metadata: [TimedMeta]
    }

    static func decode(_ data: Data, name: String = "Imported MIDI") throws -> Project {
        guard data.count <= maxFileBytes else {
            throw invalid("MIDI file exceeds the 64 MB import safety limit")
        }
        var reader = Reader(bytes: Array(data))
        guard try reader.read(4) == Array("MThd".utf8) else {
            throw invalid("Missing Standard MIDI File header")
        }
        let headerLength = try reader.long()
        guard headerLength >= 6, headerLength <= 1024 else {
            throw invalid("Invalid MIDI header length")
        }
        let format = try reader.word()
        let trackCount = try reader.word()
        let division = try reader.word()
        _ = try reader.read(headerLength - 6)
        guard format == 0 || format == 1,
              trackCount > 0 && trackCount <= maxTrackCount,
              (format != 0 || trackCount == 1) else {
            throw invalid("Only Standard MIDI File format 0 and 1 are supported")
        }
        guard division & 0x8000 == 0, division > 0 else {
            throw invalid("SMPTE-time MIDI files are not yet supported; use PPQ MIDI")
        }

        var parsed: [ParsedTrack] = []
        var allMetadata: [TimedMeta] = []
        for trackIndex in 0..<trackCount {
            guard try reader.read(4) == Array("MTrk".utf8) else {
                throw invalid("Missing MIDI track chunk")
            }
            let length = try reader.long()
            guard length <= reader.bytes.count - reader.offset else {
                throw invalid("MIDI track extends past the end of the file")
            }
            let chunk = try reader.read(length)
            let next = try parseTrack(chunk, division: division, trackIndex: trackIndex)
            parsed.append(next)
            allMetadata.append(contentsOf: next.metadata)
        }
        guard reader.offset == reader.bytes.count else {
            throw invalid("Unexpected bytes after the last MIDI track")
        }

        var project = Project(name: name)
        let sortedMeta = allMetadata.sorted {
            $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick
        }
        for meta in sortedMeta {
            if let bpm = meta.tempo {
                if meta.tick == 0 {
                    project.tempo = Tempo(bpm: bpm)
                } else {
                    // A later event at the same tick wins, just as MIDI
                    // playback would process the successive conductor events.
                    let position = Double(meta.tick) / Double(division)
                    if let index = project.tempoChanges.firstIndex(where: {
                        $0.beatPosition == position
                    }) {
                        project.tempoChanges[index] = TempoChange(
                            beatPosition: position, tempo: Tempo(bpm: bpm))
                    } else {
                        project.tempoChanges.append(TempoChange(
                            beatPosition: position, tempo: Tempo(bpm: bpm)))
                    }
                }
            }
            if let signature = meta.signature {
                if meta.tick == 0 {
                    project.timeSignature = signature
                } else {
                    let position = Double(meta.tick) / Double(division)
                    if let index = project.timeSignatureChanges.firstIndex(where: {
                        $0.beatPosition == position
                    }) {
                        project.timeSignatureChanges[index] = TimeSignatureChange(
                            beatPosition: position, timeSignature: signature)
                    } else {
                        project.timeSignatureChanges.append(TimeSignatureChange(
                            beatPosition: position, timeSignature: signature))
                    }
                }
            }
        }

        for (index, source) in parsed.enumerated() where !source.events.isEmpty {
            var track = Track(
                name: source.name?.isEmpty == false ? source.name! :
                    "Imported MIDI \(index + 1)",
                type: .midi
            )
            // Include the last event and release at the trimmed region end.
            // A one-tick margin prevents the export planner excluding a final
            // same-beat CC, even for files with notes ending on barlines.
            let lastBeat = Double(source.maximumTick + 1) / Double(division)
            let duration = TimePosition(
                beats: max(1, lastBeat), tempo: project.tempo.bpm,
                sampleRate: project.sampleRate
            )
            track.clips = [Clip(
                name: track.name,
                timeRange: TimeRange(
                    start: TimePosition(samples: 0, sampleRate: project.sampleRate),
                    duration: duration
                ),
                content: .midi(MIDIClipData(events: source.events))
            )]
            project.tracks.append(track)
        }
        return project
    }

    private static func parseTrack(_ bytes: [UInt8], division: Int,
                                   trackIndex: Int) throws -> ParsedTrack {
        var reader = Reader(bytes: bytes)
        var tick = 0
        var sequence = 0
        var maximumTick = 0
        var runningStatus: UInt8?
        var pending: [UInt16: [PendingNote]] = [:]
        var entries: [EventEntry] = []
        var metadata: [TimedMeta] = []
        var name: String?
        var ended = false

        func append(_ event: MIDIEvent, at eventTick: Int,
                    originalOrder: Int, endingAt end: Int? = nil) throws {
            guard entries.count < maxEvents else {
                throw invalid("MIDI file has too many events")
            }
            entries.append(EventEntry(tick: eventTick, sequence: originalOrder,
                                      event: event, endTick: end ?? eventTick))
            maximumTick = max(maximumTick, end ?? eventTick)
        }

        while reader.offset < bytes.count {
            let delta = try reader.vlq()
            guard tick <= maxTick - delta else {
                throw invalid("MIDI position exceeds the supported tick range")
            }
            tick += delta
            let next = try reader.byte()
            let status: UInt8
            if next & 0x80 != 0 {
                status = next
                if status < 0xF0 { runningStatus = status }
                else { runningStatus = nil }
            } else {
                guard let running = runningStatus else {
                    throw invalid("Running-status MIDI data without a status byte")
                }
                status = running
                reader.offset -= 1 // The first data byte belongs to this event.
            }
            sequence += 1

            if status == 0xFF {
                let type = try reader.byte()
                let length = try reader.vlq()
                let payload = try reader.read(length)
                switch type {
                case 0x2F:
                    guard payload.isEmpty, reader.offset == bytes.count else {
                        throw invalid("Malformed MIDI end-of-track event")
                    }
                    ended = true
                case 0x03:
                    name = String(bytes: payload.prefix(1024), encoding: .utf8)
                        ?? String(bytes: payload.prefix(1024), encoding: .isoLatin1)
                case 0x51:
                    guard payload.count == 3 else { throw invalid("Bad MIDI tempo event") }
                    let us = (Int(payload[0]) << 16) | (Int(payload[1]) << 8)
                        | Int(payload[2])
                    guard us > 0 else { throw invalid("Zero MIDI tempo") }
                    let bpm = 60_000_000.0 / Double(us)
                    guard bpm >= 20, bpm <= 999 else {
                        throw invalid("Imported MIDI tempo is outside Studio's supported range")
                    }
                    metadata.append(TimedMeta(
                        tick: tick, order: trackIndex * maxEvents + sequence,
                        tempo: bpm, signature: nil))
                case 0x58:
                    guard payload.count == 4, payload[0] > 0, payload[1] <= 7 else {
                        throw invalid("Bad MIDI time signature event")
                    }
                    metadata.append(TimedMeta(
                        tick: tick, order: trackIndex * maxEvents + sequence,
                        tempo: nil, signature: TimeSignature(
                            numerator: Int(payload[0]),
                            denominator: 1 << Int(payload[1]))))
                default:
                    // Text, key signature, device names and other non-musical
                    // metadata have no corresponding Studio project field.
                    break
                }
                if ended { break }
                continue
            }
            if status == 0xF0 {
                let length = try reader.vlq()
                let payload = try reader.read(length)
                try append(MIDIEvent(
                    beatPosition: Double(tick) / Double(division),
                    type: .sysex(data: Data([0xF0] + payload))
                ), at: tick, originalOrder: sequence)
                continue
            }
            guard status < 0xF0 else {
                throw invalid("Unsupported MIDI system event (including F7 continuation)")
            }
            let channel = status & 0x0F
            let command = status & 0xF0
            let data1 = try reader.byte()
            guard data1 < 128 else { throw invalid("Invalid MIDI data byte") }
            let data2: UInt8
            if command == 0xC0 || command == 0xD0 {
                data2 = 0
            } else {
                data2 = try reader.byte()
                guard data2 < 128 else { throw invalid("Invalid MIDI data byte") }
            }
            let beat = Double(tick) / Double(division)
            switch command {
            case 0x80, 0x90:
                let key = UInt16(channel) << 8 | UInt16(data1)
                if command == 0x90 && data2 > 0 {
                    pending[key, default: []].append(PendingNote(
                        tick: tick, sequence: sequence, velocity: data2))
                } else if var open = pending[key], !open.isEmpty {
                    let note = open.removeFirst()
                    pending[key] = open
                    let duration = Double(tick - note.tick) / Double(division)
                    let event = MIDIEvent(
                        beatPosition: Double(note.tick) / Double(division),
                        type: .note(NoteData(
                            pitch: data1, velocity: note.velocity,
                            duration: duration,
                            releaseVelocity: command == 0x80 ? data2 : 0)),
                        channel: channel
                    )
                    try append(event, at: note.tick, originalOrder: note.sequence,
                               endingAt: tick)
                } else {
                    // Preserve unmatched note-off instead of silently dropping
                    // MIDI. This remains an explicit velocity-zero event.
                    try append(MIDIEvent(
                        beatPosition: beat,
                        type: .note(NoteData(
                            pitch: data1, velocity: 0, duration: 0,
                            releaseVelocity: command == 0x80 ? data2 : 0)),
                        channel: channel
                    ), at: tick, originalOrder: sequence)
                }
            case 0xA0:
                try append(MIDIEvent(beatPosition: beat,
                    type: .polyAftertouch(note: data1, pressure: data2),
                    channel: channel), at: tick, originalOrder: sequence)
            case 0xB0:
                try append(MIDIEvent.controlChange(
                    at: beat, controller: data1, value: data2,
                    channel: channel), at: tick, originalOrder: sequence)
            case 0xC0:
                try append(MIDIEvent(beatPosition: beat,
                    type: .programChange(program: data1), channel: channel),
                    at: tick, originalOrder: sequence)
            case 0xD0:
                try append(MIDIEvent(beatPosition: beat,
                    type: .aftertouch(pressure: data1), channel: channel),
                    at: tick, originalOrder: sequence)
            case 0xE0:
                let unsigned = Int(data1) | (Int(data2) << 7)
                try append(MIDIEvent.pitchBend(
                    at: beat, value: Int16(unsigned - 8192),
                    channel: channel), at: tick, originalOrder: sequence)
            default:
                throw invalid("Unsupported MIDI channel message")
            }
        }
        guard ended else { throw invalid("Missing MIDI end-of-track event") }
        guard pending.values.allSatisfy({ $0.isEmpty }) else {
            throw invalid("Unclosed MIDI note-on at end of track")
        }
        entries.sort {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            return $0.sequence < $1.sequence
        }
        return ParsedTrack(name: name, events: entries.map(\.event),
                           maximumTick: maximumTick, metadata: metadata)
    }

    private static func invalid(_ reason: String) -> PersistenceError {
        .invalidFormat(reason)
    }
}
