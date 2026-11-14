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
        guard anchor.isFinite, anchor >= 0, !notes.isEmpty else { return [] }
        let source = notes.filter {
            if case .note = $0.type { return $0.beatPosition.isFinite }
            return false
        }
        guard let earliest = source.map(\.beatPosition).min() else { return [] }
        var inserted = Set<UUID>()
        for note in source {
            var copy = note
            copy.id = UUID()
            copy.beatPosition = anchor + (note.beatPosition - earliest)
            events.append(copy)
            inserted.insert(copy.id)
        }
        return inserted
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
        let intendedAnchor = StudioMusicalGrid.snap(
            earliestAbsolute + beatDelta, division: division, bypass: bypassSnap
        )
        let appliedDelta = intendedAnchor - earliestAbsolute
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

    /// Keep the opposite edge fixed and never produce zero/negative length notes.
    static func resizing(_ events: [MIDIEvent], noteID: UUID, edge: ResizeEdge,
                         beatDelta: Double, division: Double, bypassSnap: Bool = false,
                         minimumDuration: Double = 0.0625) -> [MIDIEvent] {
        guard beatDelta.isFinite else { return events }
        return events.map { event in
            guard event.id == noteID, case .note(var note) = event.type else {
                return event
            }
            let minLength = max(0.001, minimumDuration)
            let start = event.beatPosition
            let end = start + note.duration
            var updated = event

            switch edge {
            case .start:
                let intended = StudioMusicalGrid.snap(
                    start + beatDelta, division: division, bypass: bypassSnap
                )
                updated.beatPosition = min(max(0, intended), max(0, end - minLength))
                note.duration = end - updated.beatPosition
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
}
