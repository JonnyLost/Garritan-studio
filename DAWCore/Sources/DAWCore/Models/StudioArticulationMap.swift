import Foundation

/// An articulation is a musical instruction. Its stable key stays on each
/// composed note; the instrument's customizable map translates it into MIDI.
/// No raw keyswitches or CC commands are stored in note assignments.
public struct StudioArticulationMap: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var articulations: [StudioArticulationDefinition]

    public init(id: UUID = UUID(), name: String = "Custom Articulations",
                articulations: [StudioArticulationDefinition] = []) {
        self.id = id
        self.name = name
        self.articulations = articulations
    }

    public func definition(for key: String) -> StudioArticulationDefinition? {
        articulations.first { $0.id == key }
    }

    public static var starter: StudioArticulationMap {
        StudioArticulationMap(name: "My Articulations", articulations: [
            StudioArticulationDefinition(id: "sustain", name: "Sustain",
                colorHex: "#5286C6", actions: []),
            StudioArticulationDefinition(id: "legato", name: "Legato",
                colorHex: "#4CA87D", actions: []),
            StudioArticulationDefinition(id: "staccato", name: "Staccato",
                colorHex: "#D49A51", actions: []),
            StudioArticulationDefinition(id: "pizzicato", name: "Pizzicato",
                colorHex: "#A27DD2", actions: [])
        ])
    }
}

/// A stable articulation name/key and one or more MIDI translation steps.
/// Empty actions are deliberately silent until configured for a real patch.
public struct StudioArticulationDefinition: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var group: String
    public var colorHex: String
    public var actions: [StudioArticulationAction]

    public init(id: String, name: String, group: String = "",
                colorHex: String = "#5286C6",
                actions: [StudioArticulationAction] = []) {
        self.id = id
        self.name = name
        self.group = group
        self.colorHex = colorHex
        self.actions = actions
    }
}

public enum StudioArticulationActionKind: String, Codable, Sendable, CaseIterable {
    case keyswitch = "Keyswitch"
    case controller = "Controller"
    case programChange = "Program Change"
    case noteChannel = "Note Channel"
}

/// A customizable MIDI command. `number` is a note, controller, or program;
/// `value` is velocity or CC value; `channel` is zero based (0...15).
public struct StudioArticulationAction: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: StudioArticulationActionKind
    public var number: Int
    public var value: Int
    public var channel: Int
    /// A held keyswitch or controller stays active for the assigned note;
    /// a latching command remains set until replaced by another command.
    public var holdForNote: Bool

    public init(id: UUID = UUID(), kind: StudioArticulationActionKind = .keyswitch,
                number: Int = 24, value: Int = 100, channel: Int = 0,
                holdForNote: Bool = false) {
        self.id = id
        self.kind = kind
        self.number = number
        self.value = value
        self.channel = channel
        self.holdForNote = holdForNote
    }
}

/// A per-note musical designation, independent of any MIDI transport command.
public struct StudioNoteArticulation: Codable, Sendable, Equatable {
    public var noteID: UUID
    public var articulationID: String

    public init(noteID: UUID, articulationID: String) {
        self.noteID = noteID
        self.articulationID = articulationID
    }
}

/// Build an ephemeral playback MIDI stream; never bake keyswitches into user
/// note events. Safe to call again when a project, map, or instrument changes.
public enum StudioArticulationRenderer {
    public static func events(for midi: MIDIClipData, map: StudioArticulationMap?) -> [MIDIEvent] {
        guard let map, let assignments = midi.articulations, !assignments.isEmpty else {
            return midi.events
        }
        let byNote = Dictionary(assignments.map { ($0.noteID, $0.articulationID) },
                                uniquingKeysWith: { _, new in new })
        var result: [(event: MIDIEvent, priority: Int, originalOrder: Int)] = []
        for (order, original) in midi.events.enumerated() {
            var noteEvent = original
            if case .note(let note) = original.type,
               let key = byNote[original.id],
               let articulation = map.definition(for: key) {
                for action in articulation.actions where action.kind == .noteChannel {
                    if (0...15).contains(action.channel) {
                        noteEvent.channel = UInt8(action.channel)
                    }
                }
                // Commands precede the note. For positive note positions use
                // a short lead-in so instruments can register the switch;
                // at region start the MIDI-event order still precedes note-on.
                let switchBeat = max(0, original.beatPosition - 0.01)
                for action in articulation.actions {
                    guard (0...15).contains(action.channel) else { continue }
                    let channel = UInt8(action.channel)
                    switch action.kind {
                    case .keyswitch:
                        guard (0...127).contains(action.number),
                              (1...127).contains(action.value) else { continue }
                        let duration = action.holdForNote
                            ? max(0.01, note.duration + original.beatPosition - switchBeat)
                            : 0.04
                        let switchNote = MIDIEvent.note(
                            at: switchBeat, pitch: UInt8(action.number),
                            velocity: UInt8(action.value), duration: duration,
                            channel: channel)
                        result.append((switchNote, 0, order))
                    case .controller:
                        guard (0...127).contains(action.number),
                              (0...127).contains(action.value) else { continue }
                        result.append((MIDIEvent.controlChange(
                            at: switchBeat, controller: UInt8(action.number),
                            value: UInt8(action.value), channel: channel), 0, order))
                        if action.holdForNote {
                            result.append((MIDIEvent.controlChange(
                                at: max(original.beatPosition,
                                        original.beatPosition + note.duration - 0.001),
                                controller: UInt8(action.number), value: 0,
                                channel: channel), -1, order))
                        }
                    case .programChange:
                        guard (0...127).contains(action.number) else { continue }
                        result.append((MIDIEvent(beatPosition: switchBeat,
                            type: .programChange(program: UInt8(action.number)),
                            channel: channel), 0, order))
                    case .noteChannel:
                        break
                    }
                }
            }
            result.append((noteEvent, 1, order))
        }
        // Stable order is important for switches sharing the note's beat.
        return result.sorted {
            if $0.event.beatPosition != $1.event.beatPosition {
                return $0.event.beatPosition < $1.event.beatPosition
            }
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.originalOrder < $1.originalOrder
        }.map(\.event)
    }
}
