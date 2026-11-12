import SwiftUI
import Foundation
import AppKit
import DAWCore

// Native mouse tracking is required for reliable MIDI note-off. SwiftUI's
// zero-distance DragGesture can lose its end event when the view re-renders.
private struct KeyboardMouseCapture: NSViewRepresentable {
    var onPress: () -> Void
    var onRelease: () -> Void

    func makeNSView(context: Context) -> MouseKeyView {
        let view = MouseKeyView()
        view.onPress = onPress
        view.onRelease = onRelease
        return view
    }

    func updateNSView(_ view: MouseKeyView, context: Context) {
        view.onPress = onPress
        view.onRelease = onRelease
    }

    final class MouseKeyView: NSView {
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        private var isPressed = false
        private var mouseUpMonitor: Any?

        override func mouseDown(with event: NSEvent) {
            guard !isPressed else { return }
            isPressed = true

            // A SwiftUI state update can replace the key view between mouseDown
            // and mouseUp. Monitor the window event stream, not just this view.
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.release()
                return event
            }
            onPress?()
        }

        override func mouseUp(with event: NSEvent) {
            release()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { release() }
            super.viewWillMove(toWindow: newWindow)
        }

        deinit {
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
            }
        }

        private func release() {
            guard isPressed else { return }
            isPressed = false
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
                self.mouseUpMonitor = nil
            }
            onRelease?()
        }
    }
}

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
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    @State private var catalog = GPOKeyswitchCatalog.load()
    @State private var search = ""
    @State private var selectedPatchName: String?
    @State private var keyboardOctave = 3
    @State private var pressedPitch: UInt8?

    private var selectedArticulationID: String? {
        get {
            guard viewModel.activeKeyswitchTrackID == viewModel.selectedTrackID else { return nil }
            return viewModel.activeKeyswitchArticulationID
        }
        nonmutating set {
            viewModel.activeKeyswitchTrackID = viewModel.selectedTrackID
            viewModel.activeKeyswitchArticulationID = newValue
        }
    }

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
        let selected = canSendKeyswitch && reference != nil && selectedArticulationID != nil && reference?.id == selectedArticulationID
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
            .overlay {
                KeyboardMouseCapture(
                    onPress: {
                        let note = UInt8(pitch)
                        guard pressedPitch != note else { return }
                        if let previous = pressedPitch {
                            viewModel.stopNotePreview(pitch: previous)
                        }
                        pressedPitch = note
                        viewModel.playNotePreview(pitch: note)
                        if canSendKeyswitch, let assignment = referenceKeyswitch(pitch) {
                            selectedArticulationID = assignment.id
                        }
                    },
                    onRelease: {
                        // AppKit delivers mouseUp to the original key even when
                        // the pointer has been dragged beyond its bounds.
                        if let activePitch = pressedPitch {
                            viewModel.stopNotePreview(pitch: activePitch)
                            pressedPitch = nil
                        }
                    }
                )
            }
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
        .studioPanel()
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

    // MARK: - Cohesive articulation surfaces

    private var instrumentIdentity: some View {
        HStack(spacing: 11) {
            if let track = viewModel.selectedTrack {
                StudioInstrumentIcon(
                    name: track.name,
                    path: suggestedName,
                    size: 42
                )
                .frame(width: 50, height: 50)
                .background(palette.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
            } else {
                Image(systemName: "pianokeys")
                    .font(.system(size: 24))
                    .foregroundStyle(palette.accent)
                    .frame(width: 50, height: 50)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(activePatch?.patch ?? (suggestedName.isEmpty ? "No instrument selected" : suggestedName))
                    .font(.system(size: 21, weight: .semibold,
                                  design: palette.appearance == .gpo5Modern ? .default : .serif))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(viewModel.selectedTrack?.name ?? "Select an instrument track")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 6) {
                if canSendKeyswitch {
                    Label("READY TO PLAY", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                } else if activePatch != nil {
                    Label("REFERENCE ONLY", systemImage: "book.closed")
                        .foregroundStyle(palette.secondaryText)
                } else {
                    Label("NO KS MAP", systemImage: "info.circle")
                        .foregroundStyle(palette.secondaryText)
                }
                Text("\(activePatch?.keyswitches.count ?? 0) articulations")
                    .foregroundStyle(palette.secondaryText)
            }
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(15)
        .studioPanel()
    }

    private func articulationButton(_ assignment: GPOKeyswitchCatalog.Assignment,
                                    compact: Bool = false) -> some View {
        let selected = canSendKeyswitch && selectedArticulationID == assignment.id
        return Button {
            selectArticulation(assignment)
        } label: {
            HStack(spacing: 11) {
                Text(assignment.note)
                    .font(.system(size: compact ? 12 : 15,
                                  weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? palette.selectedText : palette.accent)
                    .frame(width: compact ? 40 : 49, height: compact ? 37 : 46)
                    .background(selected ? palette.accent : palette.accentMuted.opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 4) {
                    Text(assignment.articulation)
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .foregroundStyle(selected ? palette.selectedText : palette.primaryText)
                        .lineLimit(1)
                    Text(selected ? "ACTIVE" : (canSendKeyswitch ? "Tap to select" : "Reference only"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selected ? palette.selectedText.opacity(0.8)
                            : palette.secondaryText)
                }
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? palette.selectedText : palette.secondaryText)
                    .font(.system(size: 13))
            }
            .padding(compact ? 7 : 10)
            .background(selected ? palette.selectedBackground : palette.surface,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? palette.accent : palette.separator.opacity(0.8),
                                  lineWidth: selected ? 1.6 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canSendKeyswitch)
        .accessibilityLabel("\(assignment.articulation), keyswitch \(assignment.note)")
        .help(canSendKeyswitch
              ? "Send \(assignment.note) keyswitch for \(assignment.articulation)"
              : "Load this exact Garritan KS program to activate this articulation")
    }

    var compactControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "music.note")
                    .foregroundStyle(palette.accent)
                Text(viewModel.selectedTrack?.name ?? "No track selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text("ARTICULATIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if canSendKeyswitch {
                    Label("KS READY", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                } else {
                    Text("REFERENCE")
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .font(.system(size: 10, weight: .semibold))

            if let patch = activePatch {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(patch.keyswitches) { assignment in
                            articulationButton(assignment, compact: true)
                                .frame(width: 205)
                        }
                    }
                    .padding(.vertical, 1)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(palette.accent)
                    Text("Load a GPO5 keyswitch instrument to show its available articulations.")
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(12)
                .studioPanel()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.panel)
        .tint(palette.accent)
        .onChange(of: viewModel.selectedTrackID) { _, _ in
            selectedPatchName = nil
            selectedArticulationID = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioWorkspaceHeader(
                "Articulations",
                subtitle: "GPO5 keyswitches · \(viewModel.selectedTrack?.name ?? "No track selected")",
                symbol: "music.note"
            ) {
                if let track = viewModel.selectedTrack,
                   track.instrumentSlot?.pluginID != nil {
                    Button {
                        viewModel.openTrackInstrumentUI(track.id, preferNativeARIA: true)
                    } label: {
                        Label("Open ARIA Player", systemImage: "pianokeys")
                    }
                    .help("Open the original ARIA Player interface for the selected instrument.")
                    .buttonStyle(.bordered)
                }
                Button("Reload Catalog") { catalog = GPOKeyswitchCatalog.load() }
                    .buttonStyle(.borderless)
            }

            if let catalog {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        StudioSectionHeading("Keyswitch Programs", symbol: "list.bullet")
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(palette.secondaryText)
                            TextField("Search keyswitch patches", text: $search)
                                .textFieldStyle(.plain)
                        }
                        .font(.system(size: 12))
                        .padding(9)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)

                        HStack {
                            Text("\(catalog.patches.count) GPO5 patches")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.secondaryText)
                            Spacer(minLength: 2)
                            if suggestedPatch != nil {
                                Button("Follow Track") {
                                    selectedPatchName = nil
                                }
                                .font(.system(size: 10, weight: .medium))
                                .buttonStyle(.borderless)
                                .help("Show keyswitches for the loaded instrument")
                            }
                        }
                        .padding(.horizontal, 14)

                        List(matchingPatches, id: \.patch, selection: $selectedPatchName) { patch in
                            HStack(spacing: 9) {
                                if suggestedPatch?.patch == patch.patch {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.accent)
                                        .font(.system(size: 12))
                                } else {
                                    Image(systemName: "music.note")
                                        .foregroundStyle(palette.secondaryText)
                                        .font(.system(size: 11))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(patch.patch)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(palette.primaryText)
                                    Text("\(patch.keyswitches.count) articulations")
                                        .font(.system(size: 10))
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            .padding(.vertical, 3)
                            .tag(patch.patch)
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                    }
                    .frame(width: 250)
                    .background(palette.sidebar)
                    Rectangle()
                        .fill(palette.separator)
                        .frame(width: 1)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            instrumentIdentity

                            if let patch = activePatch {
                                StudioSectionHeading("Available Articulations",
                                                     symbol: "square.grid.2x2")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 10)],
                                          alignment: .leading, spacing: 10) {
                                    ForEach(patch.keyswitches) { assignment in
                                        articulationButton(assignment)
                                    }
                                }

                                HStack(spacing: 7) {
                                    Image(systemName: canSendKeyswitch ?
                                          "checkmark.shield.fill" : "book.closed")
                                        .foregroundStyle(canSendKeyswitch ?
                                                         Color.green : palette.accent)
                                    Text(canSendKeyswitch
                                         ? "Keyswitches control the loaded Garritan instrument."
                                         : "Manual reference only. Load the matching KS instrument to enable MIDI.")
                                        .foregroundStyle(palette.secondaryText)
                                }
                                .font(.system(size: 11))

                                StudioSectionHeading("Play & Audition", symbol: "pianokeys")
                                auditionKeyboard
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("No matching keyswitch map",
                                          systemImage: "info.circle")
                                        .font(.headline)
                                        .foregroundStyle(palette.primaryText)
                                    Text("Select a reference patch on the left, or load a GPO5 keyswitch instrument to see its articulations.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(palette.secondaryText)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .studioPanel()

                                StudioSectionHeading("Play & Audition", symbol: "pianokeys")
                                auditionKeyboard
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(17)
                    }
                    .background(palette.canvas)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("GPO5 keyswitch catalog not found", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("Place GPO5_keyswitch_catalog.json in the project's Resources folder or project root. Then select Reload Catalog.")
                    Text("Articulation reference information requires the catalog file.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(palette.canvas)
        .tint(palette.accent)
        .onDisappear {
            if let activePitch = pressedPitch {
                viewModel.stopNotePreview(pitch: activePitch)
                pressedPitch = nil
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
