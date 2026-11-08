import SwiftUI
import Foundation
import DAWCore

// Read-only first pass. MIDI triggering is intentionally deferred until ARIA octave
// numbering and patch identity have been verified on the user's installation.
private struct GPOKeyswitchCatalog: Decodable {
    struct Assignment: Decodable, Identifiable {
        let note: String
        let articulation: String
        var id: String { note + articulation }
    }
    struct Patch: Decodable {
        let patch: String
        let keyswitches: [Assignment]
    }
    let patches: [Patch]

    static func load() -> GPOKeyswitchCatalog? {
        let fm = FileManager.default
        let name = "GPO5_keyswitch_catalog"
        var candidates: [URL] = []
        if let bundled = Bundle.module.url(forResource: name, withExtension: "json") {
            candidates.append(bundled)
        }
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates += [
            root.appendingPathComponent("Resources/Articulations/\(name).json"),
            root.appendingPathComponent("Resources/\(name).json"),
            root.appendingPathComponent("\(name).json"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode(GPOKeyswitchCatalog.self, from: data) {
                return catalog
            }
        }
        return nil
    }
}

struct ArticulationsWorkspaceView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @State private var catalog = GPOKeyswitchCatalog.load()
    @State private var search = ""
    @State private var selectedPatchName: String?
    @State private var selectedArticulationID: String?
    @State private var keyboardOctave = 3
    @State private var pressedPitch: UInt8?

    private var suggestedName: String {
        guard let track = viewModel.selectedTrack else { return "" }
        // The catalog ID is the selected ARIA program path, not the user-editable track title.
        let program = track.garritanProgramID?.components(separatedBy: ":").dropFirst().joined(separator: ":") ?? ""
        return program.components(separatedBy: "/").last ?? ""
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private var suggestedPatch: GPOKeyswitchCatalog.Patch? {
        guard let catalog, !suggestedName.isEmpty else { return nil }
        let needle = normalized(suggestedName.replacingOccurrences(of: ".sfz", with: "", options: .caseInsensitive))
        // Match only unambiguous, exact patch names; never guess an articulation map.
        let matches = catalog.patches.filter { normalized($0.patch) == needle }
        return matches.count == 1 ? matches.first : nil
    }

    private var matchingPatches: [GPOKeyswitchCatalog.Patch] {
        guard let catalog else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.patches }
        return catalog.patches.filter { $0.patch.localizedCaseInsensitiveContains(query) }
    }

    private var activePatch: GPOKeyswitchCatalog.Patch? {
        guard let catalog else { return nil }
        if let selectedPatchName {
            return catalog.patches.first { $0.patch == selectedPatchName }
        }
        return suggestedPatch
    }


    // MIDI note numbers are authoritative; displayed octaves use C4 = MIDI 60.
    // Catalog keyswitches remain reference-only until ARIA's octave convention is verified.
    private func keyboardKey(_ pitch: Int, black: Bool, width: CGFloat, height: CGFloat = 90) -> some View {
        let active = pressedPitch == UInt8(pitch)
        return RoundedRectangle(cornerRadius: 3)
            .fill(active ? Color.accentColor : (black ? Color.black : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray, lineWidth: 0.5))
            .overlay(alignment: .bottom) {
                if pitch % 12 == 0 {
                    Text("C\(pitch / 12 - 1)")
                        .font(.system(size: 9))
                        .foregroundColor(active ? .white : .gray)
                        .padding(.bottom, 4)
                }
            }
            .frame(width: width, height: black ? height * 0.61 : height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    let note = UInt8(pitch)
                    guard pressedPitch != note else { return }
                    if let previous = pressedPitch { viewModel.stopNotePreview(pitch: previous) }
                    pressedPitch = note
                    viewModel.playNotePreview(pitch: note)
                }
                .onEnded { _ in
                    viewModel.stopNotePreview(pitch: UInt8(pitch))
                    if pressedPitch == UInt8(pitch) { pressedPitch = nil }
                })
            .help("MIDI note \(pitch)")
    }

    private var auditionKeyboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Playable Keyboard", systemImage: "pianokeys")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { keyboardOctave = max(0, keyboardOctave - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(keyboardOctave == 0)
                Text("C\(keyboardOctave)–B\(keyboardOctave + 2)")
                    .font(.caption.monospacedDigit())
                Button { keyboardOctave = min(7, keyboardOctave + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(keyboardOctave == 7)
            }
            .buttonStyle(.borderless)
            GeometryReader { geometry in
                let keyWidth = geometry.size.width / 21
                let start = (keyboardOctave + 1) * 12
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(0..<36, id: \.self) { offset in
                            let pitch = start + offset
                            if pitch <= 127 && ![1, 3, 6, 8, 10].contains(pitch % 12) {
                                keyboardKey(pitch, black: false, width: keyWidth)
                            }
                        }
                    }
                    ForEach(0..<36, id: \.self) { offset in
                        let pitch = start + offset
                        if pitch <= 127 && [1, 3, 6, 8, 10].contains(pitch % 12) {
                            let precedingWhiteKeys = (0..<offset).filter {
                                ![1, 3, 6, 8, 10].contains((start + $0) % 12)
                            }.count
                            keyboardKey(pitch, black: true, width: keyWidth * 0.62)
                                .offset(x: CGFloat(precedingWhiteKeys) * keyWidth - keyWidth * 0.31)
                                .zIndex(1)
                        }
                    }
                }
            }
            .frame(height: 92)
            Text("Hold a key to audition the selected instrument. Keyswitch assignments are not transmitted yet.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }


    // Compact mode shares the same catalog and patch-matching logic as the full editor.
    private var compactKeyboard: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text("Keyboard").font(.caption2.weight(.semibold))
                Spacer()
                Button { keyboardOctave = max(0, keyboardOctave - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(keyboardOctave == 0)
                Text("C\(keyboardOctave)–B\(keyboardOctave + 2)")
                    .font(.caption2.monospacedDigit())
                Button { keyboardOctave = min(7, keyboardOctave + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(keyboardOctave == 7)
            }
            .buttonStyle(.borderless)
            GeometryReader { geometry in
                let keyWidth = geometry.size.width / 21
                let start = (keyboardOctave + 1) * 12
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(0..<36, id: \.self) { offset in
                            let pitch = start + offset
                            if pitch <= 127 && ![1, 3, 6, 8, 10].contains(pitch % 12) {
                                keyboardKey(pitch, black: false, width: keyWidth, height: 45)
                            }
                        }
                    }
                    ForEach(0..<36, id: \.self) { offset in
                        let pitch = start + offset
                        if pitch <= 127 && [1, 3, 6, 8, 10].contains(pitch % 12) {
                            let precedingWhiteKeys = (0..<offset).filter {
                                ![1, 3, 6, 8, 10].contains((start + $0) % 12)
                            }.count
                            keyboardKey(pitch, black: true, width: keyWidth * 0.62, height: 45)
                                .offset(x: CGFloat(precedingWhiteKeys) * keyWidth - keyWidth * 0.31)
                                .zIndex(1)
                        }
                    }
                }
            }
            .frame(height: 46)
        }
        .frame(minWidth: 250)
    }

    var compactControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.selectedTrack?.name ?? "No track selected")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(activePatch?.patch ?? "No matching keyswitch map")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            Divider()
            if let patch = activePatch {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(patch.keyswitches) { assignment in
                            Button {
                                selectedArticulationID = assignment.id
                            } label: {
                                VStack(spacing: 3) {
                                    Text(assignment.articulation)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(assignment.note)
                                        .font(.caption2.monospaced())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedArticulationID == assignment.id
                                    ? Color.accentColor.opacity(0.2)
                                    : Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(7)
                            }
                            .buttonStyle(.plain)
                            .help("Reference keyswitch: \\(assignment.note). MIDI transmission not enabled.")
                        }
                    }
                }
                .frame(maxWidth: 280)
            } else {
                Text("Load a matching GPO5 KS patch to see articulation shortcuts")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Divider()
            compactKeyboard
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedTrackID) { _, _ in
            selectedPatchName = nil
            selectedArticulationID = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Articulations").font(.headline)
                    Text("GPO5 keyswitch reference • \(viewModel.selectedTrack?.name ?? "No track selected")")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if let track = viewModel.selectedTrack,
                   let pluginID = track.instrumentSlot?.pluginID {
                    Button {
                        if let loaded = viewModel.pluginHost.loadedPlugins.values.first(where: {
                            $0.identifier == pluginID
                        }) {
                            PluginWindowManager.shared.openPluginWindow(
                                for: loaded, trackName: track.name, preferNativeARIA: true)
                        }
                    } label: {
                        Label("Open ARIA Player", systemImage: "pianokeys")
                    }
                    .help("Open the original ARIA Player interface for the selected instrument.")
                    .buttonStyle(.bordered)
                }
                Button("Reload Catalog") { catalog = GPOKeyswitchCatalog.load() }
                    .buttonStyle(.borderless)
            }
            .padding(14)
            Divider()

            if let catalog {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Find a GPO5 keyswitch patch", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                        Text("\(catalog.patches.count) documented KS patches")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                        List(matchingPatches, id: \.patch, selection: $selectedPatchName) { patch in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(patch.patch).font(.subheadline)
                                Text("\(patch.keyswitches.count) articulations")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            .tag(patch.patch)
                        }
                        .listStyle(.sidebar)
                    }
                    .frame(minWidth: 230, idealWidth: 290, maxWidth: 340)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            auditionKeyboard
                            Divider()
                            if let patch = activePatch {
                                Text(patch.patch).font(.title3.weight(.semibold))
                                Text("Reference assignments from the GPO5 owner's manual. These controls do not transmit MIDI yet.")
                                    .font(.caption).foregroundColor(.secondary)
                                if selectedPatchName == nil && suggestedPatch?.patch == patch.patch {
                                    Label("Matched to loaded Garritan program", systemImage: "checkmark.circle")
                                        .font(.caption).foregroundColor(.green)
                                } else {
                                    Text("Manual reference selection")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                ForEach(patch.keyswitches) { assignment in
                                    Button {
                                        selectedArticulationID = assignment.id
                                    } label: {
                                        HStack(spacing: 16) {
                                            Image(systemName: selectedArticulationID == assignment.id ? "largecircle.fill.circle" : "circle")
                                                .foregroundColor(.accentColor)
                                            Text(assignment.note)
                                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                                .frame(width: 52, alignment: .leading)
                                            Text(assignment.articulation)
                                            Spacer()
                                        }
                                        .padding(10)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(7)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\\(assignment.articulation), keyswitch \\(assignment.note)")
                                }
                            } else {
                                Text("Select a keyswitch patch from the list, or load a matching Garritan KS program.")
                                    .foregroundColor(.secondary)
                                Text("Only exact matches to the loaded Garritan program are suggested. Manual selection remains available.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("GPO5 keyswitch catalog not found").font(.headline)
                    Text("Place GPO5_keyswitch_catalog.json in the project's Resources folder, beside the project root, or in your Downloads folder. Then select Reload Catalog.")
                    Text("The catalog contains manual-derived reference data. MIDI playback and automatic patch matching will be added after verification.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
        .onChange(of: viewModel.selectedTrackID) { _, _ in
            if let pressedPitch { viewModel.stopNotePreview(pitch: pressedPitch) }
            pressedPitch = nil
            selectedPatchName = nil
            selectedArticulationID = nil
        }
        .onChange(of: selectedPatchName) { _, _ in
            selectedArticulationID = nil
        }
    }
}
