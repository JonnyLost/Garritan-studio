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


    // Reference overlay only: the manual's octave labels are not yet calibrated
    // against ARIA's actual MIDI keyswitch note numbers.
    private func referencePitch(_ label: String) -> Int? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let names = ["C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3,
                     "E": 4, "F": 5, "F#": 6, "GB": 6, "G": 7,
                     "G#": 8, "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11]
        let prefix = String(text.prefix { !$0.isNumber && $0 != "-" })
        guard let semitone = names[prefix],
              let octave = Int(text.dropFirst(prefix.count)) else { return nil }
        let pitch = (octave + 1) * 12 + semitone
        return (0...127).contains(pitch) ? pitch : nil
    }

    private var canSendKeyswitch: Bool {
        guard let activePatch, let suggestedPatch, viewModel.selectedTrack != nil else { return false }
        return activePatch.patch == suggestedPatch.patch
    }

    private func selectArticulation(_ assignment: GPOKeyswitchCatalog.Assignment) {
        guard canSendKeyswitch, let pitch = referencePitch(assignment.note) else { return }
        selectedArticulationID = assignment.id
        let note = UInt8(pitch)
        viewModel.playNotePreview(pitch: note)
        viewModel.stopNotePreview(pitch: note)
    }

    private func referenceKeyswitch(_ pitch: Int) -> GPOKeyswitchCatalog.Assignment? {
        activePatch?.keyswitches.first { referencePitch($0.note) == pitch }
    }

    // MIDI note numbers are authoritative; displayed octaves use C4 = MIDI 60.
    // Catalog keyswitches remain reference-only until ARIA's octave convention is verified.
    private func keyboardKey(_ pitch: Int, black: Bool, width: CGFloat, height: CGFloat = 90) -> some View {
        let active = pressedPitch == UInt8(pitch)
        let reference = referenceKeyswitch(pitch)
        let selected = canSendKeyswitch && reference?.id == selectedArticulationID
        return RoundedRectangle(cornerRadius: 3)
            .fill(active || selected ? Color.accentColor : (black ? Color.black : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.accentColor : (reference == nil ? (black ? Color.black : Color.gray.opacity(0.4)) : Color.orange), lineWidth: selected ? 2 : (reference == nil ? 0.6 : 1.5)))
            .overlay(alignment: .top) {
                if reference != nil {
                    Circle().fill(selected ? Color.white : Color.orange).frame(width: 5, height: 5).padding(.top, 3)
                }
            }
            .overlay(alignment: .bottom) {
                if pitch % 12 == 0 {
                    Text("C\(pitch / 12 - 1)")
                        .font(.system(size: 9))
                        .foregroundColor(active || selected ? .white : .gray)
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
                    if canSendKeyswitch, let assignment = referenceKeyswitch(pitch) {
                        selectedArticulationID = assignment.id
                    }
                }
                .onEnded { _ in
                    viewModel.stopNotePreview(pitch: UInt8(pitch))
                    if pressedPitch == UInt8(pitch) { pressedPitch = nil }
                })
            .help(reference.map { "\($0.articulation) — \($0.note)" } ?? "MIDI note \(pitch)")
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
            Text("Hold a key to audition the selected instrument. Matched keyswitch notes also select their articulation.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }


    // Compact mode shares the same catalog and patch-matching logic as the full editor.
    // Full concert piano range (A0–C8, MIDI 21–108) scaled to the dock width.
    var dockedKeyboard: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text("88-Key Keyboard").font(.caption2.weight(.semibold))
                Spacer()
                if activePatch != nil {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("GPO5 keyswitches")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text("A0–C8")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            GeometryReader { geometry in
                let whiteKeyWidth = geometry.size.width / 52
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(21...108, id: \.self) { pitch in
                            if ![1, 3, 6, 8, 10].contains(pitch % 12) {
                                keyboardKey(pitch, black: false, width: whiteKeyWidth, height: 62)
                            }
                        }
                    }
                    ForEach(21...108, id: \.self) { pitch in
                        if [1, 3, 6, 8, 10].contains(pitch % 12) {
                            let precedingWhiteKeys = (21..<pitch).filter {
                                ![1, 3, 6, 8, 10].contains($0 % 12)
                            }.count
                            keyboardKey(pitch, black: true, width: whiteKeyWidth * 0.65, height: 62)
                                .offset(x: CGFloat(precedingWhiteKeys) * whiteKeyWidth - whiteKeyWidth * 0.325)
                                .zIndex(1)
                        }
                    }
                }
            }
            .frame(height: 63)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                                selectArticulation(assignment)
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
                                .foregroundColor(selectedArticulationID == assignment.id ? .white : .primary)
                                .background(selectedArticulationID == assignment.id
                                    ? Color.accentColor
                                    : Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(7)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSendKeyswitch)
                            .help(canSendKeyswitch ? "Send \\(assignment.note) keyswitch" : "Load this exact GPO5 KS program to enable switching.")
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
                                Text("Reference assignments from the GPO5 manual. MIDI enabled only for the exact loaded KS program.")
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
                                        selectArticulation(assignment)
                                    } label: {
                                        HStack(spacing: 16) {
                                            Image(systemName: selectedArticulationID == assignment.id ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(selectedArticulationID == assignment.id ? .white : .accentColor)
                                            Text(assignment.note)
                                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                                .frame(width: 52, alignment: .leading)
                                            Text(assignment.articulation)
                                            Spacer()
                                        }
                                        .padding(10)
                                        .foregroundColor(selectedArticulationID == assignment.id ? .white : .primary)
                                        .background(selectedArticulationID == assignment.id ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(7)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canSendKeyswitch)
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
        .onChange(of: suggestedName) { _, _ in
            selectedPatchName = nil
            selectedArticulationID = nil
        }
    }
}
