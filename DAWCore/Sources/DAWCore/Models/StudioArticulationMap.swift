import Foundation

/// An articulation is a musical instruction. Its stable key stays on each
/// composed note; the instrument's customizable map translates it into MIDI.
/// No raw keyswitches or CC commands are stored in note assignments.
public struct StudioArticulationMap: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var articulations: [StudioArticulationDefinition]
    /// The exact Garritan program from which a factory map was built.
    /// Optional for old projects and independent user-created maps.
    public var factoryProgramID: String?
    /// Only untouched factory maps may be automatically replaced when a new
    /// Garritan program loads. Editing a map clears this flag.
    public var isFactoryDefault: Bool?

    public init(id: UUID = UUID(), name: String = "Custom Articulations",
                articulations: [StudioArticulationDefinition] = [],
                factoryProgramID: String? = nil,
                isFactoryDefault: Bool? = nil) {
        self.id = id
        self.name = name
        self.articulations = articulations
        self.factoryProgramID = factoryProgramID
        self.isFactoryDefault = isFactoryDefault
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
    private struct KeyswitchKey: Hashable {
        let pitch: UInt8
        let channel: UInt8
        let beat: Double
    }

    private struct HeldControllerKey: Hashable {
        let controller: UInt8
        let channel: UInt8
    }

    public static func events(for midi: MIDIClipData, map: StudioArticulationMap?) -> [MIDIEvent] {
        let audible = midi.events.filter { event in
            guard case .note(let note) = event.type else { return true }
            return note.isMuted != true
        }
        guard let map, let assignments = midi.articulations, !assignments.isEmpty else {
            return audible
        }
        let byNote = Dictionary(assignments.map { ($0.noteID, $0.articulationID) },
                                uniquingKeysWith: { _, new in new })
        var result: [(event: MIDIEvent, priority: Int, originalOrder: Int)] = []
        var emittedSwitches = Set<KeyswitchKey>()
        var heldControllerWindows: [HeldControllerKey: [(start: Double, end: Double)]] = [:]
        for (order, original) in audible.enumerated() {
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
                        // Same keyswitch at the same beat may be shared by
                        // a chord. Send it once; repeated note-on/note-off
                        // pairs could otherwise release a held switch early.
                        let repeatKey = KeyswitchKey(
                            pitch: UInt8(action.number), channel: channel,
                            beat: switchBeat)
                        if action.holdForNote ||
                            emittedSwitches.insert(repeatKey).inserted {
                            let switchNote = MIDIEvent.note(
                                at: switchBeat, pitch: UInt8(action.number),
                                velocity: UInt8(action.value),
                                duration: duration, channel: channel)
                            result.append((switchNote, 0, order))
                        }
                    case .controller:
                        guard (0...127).contains(action.number),
                              (0...127).contains(action.value) else { continue }
                        result.append((MIDIEvent.controlChange(
                            at: switchBeat, controller: UInt8(action.number),
                            value: UInt8(action.value), channel: channel), 0, order))
                        if action.holdForNote {
                            let controllerKey = HeldControllerKey(
                                controller: UInt8(action.number), channel: channel)
                            heldControllerWindows[controllerKey, default: []].append((
                                start: switchBeat,
                                end: original.beatPosition + note.duration))
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
        // A controller held by overlapping notes cannot be reset when
        // the first note ends. Merge overlapping windows per channel/CC
        // and emit ONE release after the last note in each active group.
        // Allow 0.01 beat of switch lead-in for adjacent articulations.
        for (key, windows) in heldControllerWindows {
            let sorted = windows.sorted { $0.start < $1.start }
            guard let first = sorted.first else { continue }
            var activeEnd = first.end
            for window in sorted.dropFirst() {
                if window.start <= activeEnd + 0.001 {
                    activeEnd = max(activeEnd, window.end)
                } else {
                    result.append((MIDIEvent.controlChange(
                        at: max(0, activeEnd - 0.001),
                        controller: key.controller, value: 0,
                        channel: key.channel), -1, midi.events.count))
                    activeEnd = window.end
                }
            }
            result.append((MIDIEvent.controlChange(
                at: max(0, activeEnd - 0.001),
                controller: key.controller, value: 0,
                channel: key.channel), -1, midi.events.count))
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
