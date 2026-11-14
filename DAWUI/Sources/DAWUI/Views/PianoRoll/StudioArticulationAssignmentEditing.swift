import Foundation
import DAWCore

/// Apply named articulations without changing MIDI note data or inserting
/// keyswitch events into the editable project. Note-only: CC event UUIDs ignored.
enum StudioArticulationAssignmentEditing {
    @discardableResult
    static func assign(_ articulationID: String?, to noteIDs: Set<UUID>,
                       in midi: inout MIDIClipData) -> Bool {
        guard !noteIDs.isEmpty else { return false }
        let existingNotes = Set(midi.events.compactMap { event -> UUID? in
            guard case .note = event.type, noteIDs.contains(event.id) else {
                return nil
            }
            return event.id
        })
        guard !existingNotes.isEmpty else { return false }
        var assignments = midi.articulations ?? []
        let before = assignments
        assignments.removeAll { existingNotes.contains($0.noteID) }
        if let articulationID {
            for noteID in existingNotes.sorted(by: { $0.uuidString < $1.uuidString }) {
                assignments.append(StudioNoteArticulation(
                    noteID: noteID, articulationID: articulationID))
            }
        }
        guard assignments != before else { return false }
        midi.articulations = assignments.isEmpty ? nil : assignments
        return true
    }

    /// Preserve articulations when MIDI notes are duplicated or pasted.
    @discardableResult
    static func transfer(from source: [UUID: String], idMapping: [UUID: UUID],
                         into midi: inout MIDIClipData) -> Bool {
        guard !source.isEmpty, !idMapping.isEmpty else { return false }
        var assignments = midi.articulations ?? []
        var added = false
        for (oldID, newID) in idMapping {
            guard let key = source[oldID] else { continue }
            assignments.removeAll { $0.noteID == newID }
            assignments.append(StudioNoteArticulation(noteID: newID, articulationID: key))
            added = true
        }
        if added { midi.articulations = assignments }
        return added
    }

    static func byNoteID(in midi: MIDIClipData) -> [UUID: String] {
        var dictionary: [UUID: String] = [:]
        for assignment in midi.articulations ?? [] {
            dictionary[assignment.noteID] = assignment.articulationID
        }
        return dictionary
    }
}
