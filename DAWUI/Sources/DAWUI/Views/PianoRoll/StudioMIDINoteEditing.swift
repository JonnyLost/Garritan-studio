import Foundation
import DAWCore

/// Stateless MIDI-note transformations shared by both Studio piano-roll editors.
/// Callers commit the returned events exactly once through ProjectViewModel.updateTrack,
/// never during a pointer-drag update.
enum StudioMIDINoteEditing {
    enum ResizeEdge { case start, end }

    static func selectedNotes(in events: [MIDIEvent], ids: Set<UUID>) -> [MIDIEvent] {
        events.filter { event in
            guard ids.contains(event.id), case .note = event.type else { return false }
            return true
        }.sorted { $0.beatPosition < $1.beatPosition }
    }

    /// Source positions and anchor use the same time domain (either clip-relative
    /// or track-absolute). CC and other non-note events are never copied.
    @discardableResult
    static func paste(_ notes: [MIDIEvent], into events: inout [MIDIEvent],
                      at anchor: Double) -> Set<UUID> {
        Set(pasteWithIDMapping(notes, into: &events, at: anchor).values)
    }

    /// Mapping old IDs to new IDs lets sidecar musical articulations follow
    /// duplicated/pasted notes without ever baking transport triggers into MIDI.
    @discardableResult
    static func pasteWithIDMapping(_ notes: [MIDIEvent], into events: inout [MIDIEvent],
                                   at anchor: Double) -> [UUID: UUID] {
        guard anchor.isFinite, anchor >= 0, !notes.isEmpty else { return [:] }
        let source = notes.filter {
            if case .note = $0.type { return $0.beatPosition.isFinite }
            return false
        }
        guard let earliest = source.map(\.beatPosition).min() else { return [:] }
        var mapping: [UUID: UUID] = [:]
        for note in source {
            var copy = note
            copy.id = UUID()
            copy.beatPosition = anchor + (note.beatPosition - earliest)
            events.append(copy)
            mapping[note.id] = copy.id
        }
        return mapping
    }

    /// Repeat immediately after the last selected note ends, preserving spacing.
    @discardableResult
    static func duplicateSelected(in events: inout [MIDIEvent],
                                  ids: Set<UUID>) -> Set<UUID> {
        let source = selectedNotes(in: events, ids: ids)
        guard !source.isEmpty else { return [] }
        let end = source.compactMap { event -> Double? in
            guard case .note(let note) = event.type else { return nil }
            return event.beatPosition + note.duration
        }.max() ?? 0
        return paste(source, into: &events, at: max(0, end))
    }

    static func deletingSelected(in events: [MIDIEvent], ids: Set<UUID>) -> [MIDIEvent] {
        events.filter { event in
            guard ids.contains(event.id), case .note = event.type else { return true }
            return false
        }
    }

    /// The delta is shared across selected notes so moving a chord against the
    /// beginning of the timeline does not collapse its internal timing offsets.
    static func moving(_ events: [MIDIEvent], selectedIDs: Set<UUID>,
                       beatDelta: Double, pitchDelta: Int, division: Double,
                       bypassSnap: Bool = false, clipStartBeat: Double = 0) -> [MIDIEvent] {
        let notes = selectedNotes(in: events, ids: selectedIDs)
        guard !notes.isEmpty, beatDelta.isFinite else { return events }
        let earliestAbsolute = (notes.map(\.beatPosition).min() ?? 0) + clipStartBeat
        // Vertical-only edits must not move unsnapped notes horizontally.
        let intendedAnchor = abs(beatDelta) < 0.000001
            ? earliestAbsolute
            : StudioMusicalGrid.snap(
                earliestAbsolute + beatDelta, division: division, bypass: bypassSnap
              )
        // Clip-local positions must remain non-negative even when the region
        // itself begins well after bar 1.
        let appliedDelta = max(clipStartBeat, intendedAnchor) - earliestAbsolute
        let pitches = notes.compactMap { event -> Int? in
            guard case .note(let data) = event.type else { return nil }
            return Int(data.pitch)
        }
        let minPitch = pitches.min() ?? 0
        let maxPitch = pitches.max() ?? 127
        let safePitchDelta = max(-minPitch, min(127 - maxPitch, pitchDelta))

        return events.map { event in
            guard selectedIDs.contains(event.id),
                  case .note(var data) = event.type else { return event }
            var modified = event
            modified.beatPosition = event.beatPosition + appliedDelta
            data.pitch = UInt8(Int(data.pitch) + safePitchDelta)
            modified.type = .note(data)
            return modified
        }
    }

    /// Arrow-key nudging preserves every selected note's relative rhythm and
    /// chord voicing, including originally unsnapped performance timing.
    /// Unlike pointer dragging, it advances by exactly the requested increment,
    /// without silently quantizing notes to the editor's current snap grid.
    static func nudging(_ events: [MIDIEvent], selectedIDs: Set<UUID>,
                        beatDelta: Double = 0, pitchDelta: Int = 0) -> [MIDIEvent] {
        guard beatDelta.isFinite, !selectedIDs.isEmpty else { return events }
        let selected = selectedNotes(in: events, ids: selectedIDs)
        guard !selected.isEmpty else { return events }

        let earliest = selected.map(\.beatPosition).min() ?? 0
        let appliedBeat = max(-earliest, beatDelta)
        let pitches = selected.compactMap { event -> Int? in
            guard case .note(let note) = event.type else { return nil }
            return Int(note.pitch)
        }
        let minPitch = pitches.min() ?? 0
        let maxPitch = pitches.max() ?? 127
        let appliedPitch = max(-minPitch, min(127 - maxPitch, pitchDelta))
        guard appliedBeat != 0 || appliedPitch != 0 else { return events }

        return events.map { event in
            guard selectedIDs.contains(event.id),
                  case .note(var note) = event.type else { return event }
            var moved = event
            moved.beatPosition += appliedBeat
            note.pitch = UInt8(Int(note.pitch) + appliedPitch)
            moved.type = .note(note)
            return moved
        }
    }

    /// Prevent empty undo entries when a nudge reaches the start of a
    /// region or the top/bottom of the MIDI pitch range.
    static func hasPitchOrTimingChanges(before: [MIDIEvent],
                                        after: [MIDIEvent]) -> Bool {
        guard before.count == after.count else { return true }
        for index in before.indices {
            let old = before[index]
            let new = after[index]
            guard old.id == new.id else { return true }
            if old.beatPosition != new.beatPosition { return true }
            if case .note(let oldNote) = old.type,
               case .note(let newNote) = new.type,
               oldNote.pitch != newNote.pitch { return true }
        }
        return false
    }

    /// Keep the opposite edge fixed and never produce zero/negative length notes.
    static func resizing(_ events: [MIDIEvent], noteID: UUID, edge: ResizeEdge,
                         beatDelta: Double, division: Double, bypassSnap: Bool = false,
                         minimumDuration: Double = 0.0625,
                         clipStartBeat: Double = 0) -> [MIDIEvent] {
        guard beatDelta.isFinite, abs(beatDelta) >= 0.000001 else { return events }
        return events.map { event in
            guard event.id == noteID, case .note(var note) = event.type else {
                return event
            }
            let minLength = max(0.001, minimumDuration)
            let start = event.beatPosition + clipStartBeat
            let end = start + note.duration
            var updated = event

            switch edge {
            case .start:
                let intended = StudioMusicalGrid.snap(
                    start + beatDelta, division: division, bypass: bypassSnap
                )
                let newStart = min(max(clipStartBeat, intended),
                                   max(clipStartBeat, end - minLength))
                updated.beatPosition = newStart - clipStartBeat
                note.duration = end - newStart
            case .end:
                let intended = StudioMusicalGrid.snap(
                    end + beatDelta, division: division, bypass: bypassSnap
                )
                note.duration = max(minLength, intended - start)
            }
            updated.type = .note(note)
            return updated
        }
    }
    /// Split selected notes strictly inside their sounding interval. The
    /// existing ID remains on the left half so the original articulation is
    /// retained; callers copy its semantic map to the new right-hand ID.
    static func splitting(_ events: [MIDIEvent], selectedIDs: Set<UUID>,
                          at beat: Double,
                          minimumDuration: Double = 0.001)
        -> (events: [MIDIEvent], idMapping: [UUID: UUID]) {
        guard beat.isFinite, beat >= 0, !selectedIDs.isEmpty else {
            return (events, [:])
        }
        var output: [MIDIEvent] = []
        var mapping: [UUID: UUID] = [:]
        for event in events {
            guard selectedIDs.contains(event.id),
                  case .note(let note) = event.type,
                  note.velocity > 0,
                  beat > event.beatPosition + minimumDuration,
                  beat < event.beatPosition + note.duration - minimumDuration else {
                output.append(event)
                continue
            }
            var left = event
            var leftData = note
            leftData.duration = beat - event.beatPosition
            left.type = .note(leftData)

            var right = event
            right.id = UUID()
            right.beatPosition = beat
            var rightData = note
            rightData.duration = event.beatPosition + note.duration - beat
            right.type = .note(rightData)
            output.append(left)
            output.append(right)
            mapping[event.id] = right.id
        }
        return (output, mapping)
    }

    /// Merge adjacent equal-performance notes only when articulation and
    /// channel agree. Gaps, overlaps and expressive differences must not be
    /// silently discarded by a "Glue" command.
    static func gluing(_ events: [MIDIEvent], selectedIDs: Set<UUID>,
                       articulations: [UUID: String] = [:])
        -> (events: [MIDIEvent], removedIDs: Set<UUID>) {
        guard selectedIDs.count > 1 else { return (events, []) }
        let ordered = selectedNotes(in: events, ids: selectedIDs).sorted {
            if $0.beatPosition != $1.beatPosition {
                return $0.beatPosition < $1.beatPosition
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        var merged: [UUID: MIDIEvent] = [:]
        var removed: Set<UUID> = []
        for event in ordered {
            guard case .note(let data) = event.type, data.velocity > 0 else { continue }
            let compatible = ordered.first { candidate in
                guard candidate.id != event.id, !removed.contains(candidate.id),
                      case .note(let other) = candidate.type,
                      other.velocity > 0,
                      candidate.beatPosition < event.beatPosition,
                      candidate.channel == event.channel,
                      other.pitch == data.pitch,
                      other.velocity == data.velocity,
                      other.releaseVelocity == data.releaseVelocity,
                      (other.isMuted == true) == (data.isMuted == true),
                      articulations[candidate.id] == articulations[event.id] else {
                    return false
                }
                let predecessor = merged[candidate.id] ?? candidate
                guard case .note(let priorData) = predecessor.type else { return false }
                return abs(predecessor.beatPosition + priorData.duration -
                           event.beatPosition) < 0.000001
            }
            if let previous = compatible {
                var mergedEvent = merged[previous.id] ?? previous
                if case .note(var old) = mergedEvent.type {
                    old.duration += data.duration
                    mergedEvent.type = .note(old)
                    merged[previous.id] = mergedEvent
                    removed.insert(event.id)
                }
            }
        }
        guard !removed.isEmpty else { return (events, []) }
        return (events.compactMap { event in
            if removed.contains(event.id) { return nil }
            return merged[event.id] ?? event
        }, removed)
    }

    /// An individual toggle is stored on the note and travels through
    /// duplicate, undo, clipboard, and project save/reopen operations.
    static func togglingMute(_ events: [MIDIEvent],
                             selectedIDs: Set<UUID>) -> [MIDIEvent] {
        events.map { event in
            guard selectedIDs.contains(event.id),
                  case .note(var note) = event.type, note.velocity > 0 else {
                return event
            }
            var changed = event
            note.isMuted = note.isMuted != true
            changed.type = .note(note)
            return changed
        }
    }

    /// Quantize against the arrangement's *absolute* musical grid, even in
    /// regions starting between beats. Keep every note clip-relative and
    /// leave controller events and unselected notes unchanged.
    static func quantizing(_ events: [MIDIEvent], selectedIDs: Set<UUID>,
                           division: Double, clipStartBeat: Double) -> [MIDIEvent] {
        guard division.isFinite, division > 0, clipStartBeat.isFinite else {
            return events
        }
        return events.map { event in
            guard selectedIDs.contains(event.id), case .note = event.type,
                  event.beatPosition.isFinite else { return event }
            var result = event
            let absolute = clipStartBeat + event.beatPosition
            let snapped = (absolute / division).rounded() * division
            result.beatPosition = max(0, snapped - clipStartBeat)
            return result
        }
    }

}
