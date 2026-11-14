import Foundation
import SwiftUI
import DAWCore

/// Native, offline user library. A project embeds its own map snapshot so
/// editing a saved template never silently changes older sessions.
enum StudioArticulationMapLibrary {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("Garritan Studio", isDirectory: true)
            .appendingPathComponent("Articulation Maps", isDirectory: true)
    }

    static func all() throws -> [StudioArticulationMap] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension.lowercased() == "json" }
            .map { try JSONDecoder().decode(StudioArticulationMap.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ map: StudioArticulationMap) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: directory.appendingPathComponent(map.id.uuidString + ".json"),
                       options: .atomic)
    }
}

enum StudioArticulationTint {
    static func color(_ hex: String) -> Color {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var number: UInt64 = 0
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&number) else {
            return .accentColor
        }
        return Color(.sRGB, red: Double((number >> 16) & 255) / 255,
                     green: Double((number >> 8) & 255) / 255,
                     blue: Double(number & 255) / 255, opacity: 1)
    }
}

/// The same editor is used by the track-wide and region piano rolls.
/// Saving updates a single track in one undoable operation.
struct StudioArticulationMapEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StudioArticulationMap
    @State private var library: [StudioArticulationMap] = []
    @State private var libraryMessage: String?
    let onSave: (StudioArticulationMap) -> Void

    init(map: StudioArticulationMap?, onSave: @escaping (StudioArticulationMap) -> Void) {
        _draft = State(initialValue: map ?? .starter)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("Articulation Manager").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack {
                TextField("Map name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Menu("Load User Map") {
                    if library.isEmpty {
                        Text("No saved maps").foregroundStyle(.secondary)
                    }
                    ForEach(library, id: \.id) { saved in
                        Button(saved.name) { draft = saved }
                    }
                }
                Button("Duplicate Map") {
                    // Keep articulation IDs, but give this instrument its own
                    // editable map identity and library file.
                    draft.id = UUID()
                    draft.name += " Copy"
                    libraryMessage = "Duplicated map; musical articulation IDs preserved"
                }
                .help("Create an independent map for another instrument without losing note assignments")
                Button("Save to Library") {
                    do {
                        try StudioArticulationMapLibrary.save(draft)
                        library = try StudioArticulationMapLibrary.all()
                        libraryMessage = "Saved to the local articulation-map library"
                    } catch {
                        libraryMessage = "Could not save map: \(error.localizedDescription)"
                    }
                }
                Button("Apply to Track") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Articulation names and stable IDs are separate from their MIDI commands. Factory/example names do not imply instrument-specific trigger notes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let libraryMessage {
                Text(libraryMessage).font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach($draft.articulations) { $definition in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(StudioArticulationTint.color(definition.colorHex))
                                        .frame(width: 14, height: 14)
                                    TextField("Articulation name", text: $definition.name)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Group", text: $definition.group)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                    TextField("#RRGGBB", text: $definition.colorHex)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 95)
                                    Button(role: .destructive) {
                                        draft.articulations.removeAll { $0.id == definition.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .help("Delete articulation from this map")
                                }
                                Text("Stable ID: \(definition.id)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                ForEach($definition.actions) { $action in
                                    HStack(spacing: 9) {
                                        Picker("Command", selection: $action.kind) {
                                            ForEach(StudioArticulationActionKind.allCases,
                                                    id: \.self) { kind in
                                                Text(kind.rawValue).tag(kind)
                                            }
                                        }
                                        .frame(width: 175)

                                        if action.kind != .noteChannel {
                                            Stepper(
                                                action.kind == .keyswitch ? "Note \(action.number)" :
                                                action.kind == .controller ? "CC \(action.number)" :
                                                "Program \(action.number)",
                                                value: $action.number, in: 0...127)
                                            .frame(width: 130)
                                        }

                                        if action.kind == .keyswitch || action.kind == .controller {
                                            Stepper(
                                                action.kind == .keyswitch ? "Vel \(action.value)" :
                                                "Value \(action.value)",
                                                value: $action.value,
                                                in: action.kind == .keyswitch ? 1...127 : 0...127)
                                            .frame(width: 130)
                                        }
                                        Stepper("Ch \(action.channel + 1)",
                                                value: $action.channel, in: 0...15)
                                            .frame(width: 95)
                                        if action.kind == .keyswitch || action.kind == .controller {
                                            Toggle("Hold", isOn: $action.holdForNote)
                                                .toggleStyle(.checkbox)
                                        }
                                        Spacer(minLength: 0)
                                        Button(role: .destructive) {
                                            definition.actions.removeAll { $0.id == action.id }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .help("Remove MIDI command")
                                    }
                                    .font(.caption)
                                }
                                Button {
                                    definition.actions.append(StudioArticulationAction())
                                } label: {
                                    Label("Add MIDI Command", systemImage: "plus")
                                }
                                .buttonStyle(.borderless)
                            }
                        } label: {
                            Text(definition.name.isEmpty ? "Untitled Articulation" : definition.name)
                                .font(.headline)
                        }
                    }
                    Button {
                        draft.articulations.append(StudioArticulationDefinition(
                            id: "custom-" + UUID().uuidString.lowercased(),
                            name: "New Articulation",
                            actions: [StudioArticulationAction()]))
                    } label: {
                        Label("Add Articulation", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .frame(minWidth: 860, minHeight: 500)
        .onAppear {
            do { library = try StudioArticulationMapLibrary.all() }
            catch { libraryMessage = "Could not read map library: \(error.localizedDescription)" }
        }
    }
}

/// A separate lower-workspace lane: click an assignment to remap a note,
/// without placing transport keyswitches into the composing piano roll.
struct StudioArticulationLane: View {
    let notes: [MIDIEvent] // in absolute quarter-note beats
    let assignments: [UUID: String]
    let map: StudioArticulationMap?
    let pixelsPerBeat: Double
    let width: CGFloat
    let height: CGFloat
    let onAssign: (UUID, String?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.16))
            ForEach(notes) { event in
                if case .note(let note) = event.type {
                    let key = assignments[event.id]
                    let definition = key.flatMap { map?.definition(for: $0) }
                    let durationWidth = max(22, note.duration * pixelsPerBeat)
                    Menu {
                        Button("Clear Articulation") { onAssign(event.id, nil) }
                        if let map {
                            ForEach(map.articulations) { candidate in
                                Button(candidate.name) { onAssign(event.id, candidate.id) }
                            }
                        }
                    } label: {
                        Text(definition?.name ?? (key == nil ? "—" : "Missing Map"))
                            .lineLimit(1)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .frame(width: durationWidth, height: height - 10)
                            .background(StudioArticulationTint.color(
                                definition?.colorHex ?? "#777777"),
                                in: RoundedRectangle(cornerRadius: 3))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .help("Change articulation for this MIDI note")
                    .offset(x: event.beatPosition * pixelsPerBeat, y: 5)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}
