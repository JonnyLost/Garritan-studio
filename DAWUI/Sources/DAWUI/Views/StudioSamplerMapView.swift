import SwiftUI
import UniformTypeIdentifiers
import DAWCore

/// Native sampler key/velocity mapping. Edits are staged in a draft, then
/// reloaded as one immutable instrument snapshot when Apply is pressed.
/// This deliberately does not mutate sample zones on the audio thread.
public struct StudioSamplerMapView: View {
    @ObservedObject public var viewModel: ProjectViewModel
    public let trackID: TrackID

    @State private var draft: StudioSamplerPatch?
    @State private var selectedIndex = 0
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var saved: StudioSamplerPatch? {
        viewModel.project.track(withID: trackID)?.studioSamplerPatch
    }

    private var hasChanges: Bool { draft != saved }
    private var selectedZone: StudioSamplerZone? {
        guard let draft, draft.zones.indices.contains(selectedIndex) else { return nil }
        return draft.zones[selectedIndex]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Studio Sampler — Mapping")
                        .font(.headline)
                    Text("Keyboard zones and velocity layers · native sample playback")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(draft?.zones.count ?? 0) zones")
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                Button {
                    showImporter = true
                } label: {
                    Label("Add Samples…", systemImage: "plus")
                }
                .disabled(isImporting)
                .buttonStyle(.borderedProminent)
            }

            if let patch = draft {
                HStack(spacing: 8) {
                    Text("Velocity 127")
                    Picker("Selected zone", selection: $selectedIndex) {
                        ForEach(patch.zones.indices, id: \.self) { index in
                            Text("\(index + 1): \(patch.zones[index].sampleURL.lastPathComponent)")
                                .tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360)
                    Spacer()
                    Button("Auto Map") { autoMap() }
                        .help("Rebuild note and velocity boundaries from sample filenames")
                        .disabled(isImporting)
                }
                .font(.caption).foregroundColor(.secondary)

                StudioSamplerKeyboardMap(
                    zones: patch.zones,
                    selectedIndex: selectedIndex,
                    onSelect: { selectedIndex = $0 }
                )
                .frame(height: 326)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1))

                if let zone = selectedZone {
                    zoneEditor(zone)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 42)).foregroundColor(.secondary)
                    Text("No sampler instrument loaded").font(.headline)
                    Text("Add WAV, AIFF, or other supported audio files to create a keyboard map.")
                        .font(.callout).foregroundColor(.secondary)
                    Button("Import Samples…") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage).font(.caption)
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                }
                .foregroundColor(.red)
            }
            HStack(spacing: 10) {
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text("Copying samples into Studio's library…")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(hasChanges ? "Mapping changes are not yet active" : "Current saved mapping")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Discard Changes") { restoreSaved() }
                    .disabled(!hasChanges || isImporting)
                Button("Apply Mapping") { applyMapping() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || draft?.isValid != true || isImporting)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if draft == nil { restoreSaved() } }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importSamples(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private enum Field {
        case root, lowKey, highKey, lowVelocity, highVelocity
    }

    private func binding(_ field: Field) -> Binding<Int> {
        Binding(
            get: {
                guard let zone = selectedZone else { return 0 }
                switch field {
                case .root: return Int(zone.rootNote)
                case .lowKey: return Int(zone.lowestNote)
                case .highKey: return Int(zone.highestNote)
                case .lowVelocity: return Int(zone.lowestVelocity)
                case .highVelocity: return Int(zone.highestVelocity)
                }
            },
            set: { value in
                guard var patch = draft,
                      patch.zones.indices.contains(selectedIndex) else { return }
                var zone = patch.zones[selectedIndex]
                let value = UInt8(clamping: value)
                switch field {
                case .root:
                    zone.rootNote = value
                case .lowKey:
                    zone.lowestNote = value
                    if zone.highestNote < value { zone.highestNote = value }
                case .highKey:
                    zone.highestNote = value
                    if zone.lowestNote > value { zone.lowestNote = value }
                case .lowVelocity:
                    zone.lowestVelocity = max(1, value)
                    if zone.highestVelocity < zone.lowestVelocity {
                        zone.highestVelocity = zone.lowestVelocity
                    }
                case .highVelocity:
                    zone.highestVelocity = max(1, value)
                    if zone.lowestVelocity > zone.highestVelocity {
                        zone.lowestVelocity = zone.highestVelocity
                    }
                }
                patch.zones[selectedIndex] = zone
                draft = patch
            }
        )
    }

    @ViewBuilder
    private func zoneEditor(_ zone: StudioSamplerZone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zone \(selectedIndex + 1): \(zone.sampleURL.lastPathComponent)")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("Root \(SamplerNoteNames.name(zone.rootNote)) · Key \(SamplerNoteNames.name(zone.lowestNote))–\(SamplerNoteNames.name(zone.highestNote)) · Velocity \(zone.lowestVelocity)–\(zone.highestVelocity)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Duplicate Layer") { duplicateZone() }
                    .disabled((draft?.zones.count ?? 0) >= 128)
                Button("Remove Zone", role: .destructive) { removeZone() }
                    .disabled((draft?.zones.count ?? 0) <= 1)
            }
            Divider()
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Root note").font(.caption).foregroundColor(.secondary)
                    Stepper(
                        SamplerNoteNames.name(zone.rootNote),
                        value: binding(.root), in: 0...127
                    )
                    .frame(minWidth: 118)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lowest key").font(.caption).foregroundColor(.secondary)
                    Stepper(
                        SamplerNoteNames.name(zone.lowestNote),
                        value: binding(.lowKey), in: 0...127
                    )
                    .frame(minWidth: 118)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Highest key").font(.caption).foregroundColor(.secondary)
                    Stepper(
                        SamplerNoteNames.name(zone.highestNote),
                        value: binding(.highKey), in: 0...127
                    )
                    .frame(minWidth: 118)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lowest velocity").font(.caption).foregroundColor(.secondary)
                    Stepper("\(zone.lowestVelocity)", value: binding(.lowVelocity), in: 1...127)
                        .frame(minWidth: 110)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Highest velocity").font(.caption).foregroundColor(.secondary)
                    Stepper("\(zone.highestVelocity)", value: binding(.highVelocity), in: 1...127)
                        .frame(minWidth: 110)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func restoreSaved() {
        draft = saved
        selectedIndex = 0
        errorMessage = nil
    }

    private func applyMapping() {
        guard let patch = draft, patch.isValid else { return }
        do {
            try viewModel.loadStudioSampler(for: trackID, patch: patch)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicateZone() {
        guard var patch = draft, patch.zones.indices.contains(selectedIndex),
              patch.zones.count < 128 else { return }
        patch.zones.insert(patch.zones[selectedIndex], at: selectedIndex + 1)
        selectedIndex += 1
        draft = patch
    }

    private func removeZone() {
        guard var patch = draft, patch.zones.indices.contains(selectedIndex),
              patch.zones.count > 1 else { return }
        patch.zones.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, patch.zones.count - 1)
        draft = patch
    }

    private func autoMap() {
        guard let draft else { return }
        do {
            var patch = try StudioSamplerMappingBuilder.makePatch(
                urls: draft.zones.map(\.sampleURL)
            )
            patch.instrumentKind = draft.instrumentKind
            patch.cc1Crossfade = draft.cc1Crossfade
            patch.dynamicsCC1 = draft.dynamicsCC1
            patch.expressionCC11 = draft.expressionCC11
            self.draft = patch
            selectedIndex = 0
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importSamples(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try StudioSamplerSampleLibrary.importFiles(urls)
                }.value
                let added = try StudioSamplerMappingBuilder.makePatch(urls: files)
                if var patch = draft {
                    guard patch.zones.count + added.zones.count <= 128 else {
                        throw StudioSamplerMappingBuilder.MappingError.tooManySamples
                    }
                    let first = patch.zones.count
                    patch.zones.append(contentsOf: added.zones)
                    draft = patch
                    selectedIndex = first
                } else {
                    draft = added
                    selectedIndex = 0
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Immutable, graphical note/velocity map: x = MIDI key, y = MIDI velocity.
/// Clicking a region selects its editable parameters. Regions can overlap;
/// milestone 1's playback engine still triggers one matching zone per note.
private struct StudioSamplerKeyboardMap: View {
    let zones: [StudioSamplerZone]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    private let keyWidth: CGFloat = 18
    private let velocityHeight: CGFloat = 276
    private let keyboardHeight: CGFloat = 37

    private var mapWidth: CGFloat { keyWidth * 128 }
    private let colors: [Color] = [
        .blue, .green, .orange, .purple, .teal, .pink, .indigo, .yellow
    ]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(0..<128, id: \.self) { note in
                                Rectangle()
                                    .fill(SamplerNoteNames.isBlack(note)
                                          ? Color.primary.opacity(0.08)
                                          : Color.primary.opacity(0.025))
                                    .overlay(alignment: .trailing) {
                                        Rectangle()
                                            .fill(Color.primary.opacity(note % 12 == 11 ? 0.2 : 0.07))
                                            .frame(width: 1)
                                    }
                                    .frame(width: keyWidth, height: velocityHeight)
                            }
                        }
                        ForEach([32, 64, 96, 127], id: \.self) { velocity in
                            Rectangle()
                                .fill(Color.primary.opacity(0.14))
                                .frame(width: mapWidth, height: 1)
                                .offset(y: CGFloat(127 - velocity) * velocityHeight / 127)
                        }
                        ForEach(zones.indices, id: \.self) { index in
                            let zone = zones[index]
                            let width = CGFloat(Int(zone.highestNote) - Int(zone.lowestNote) + 1) * keyWidth
                            let height = max(3, CGFloat(Int(zone.highestVelocity) - Int(zone.lowestVelocity) + 1) * velocityHeight / 127)
                            Button {
                                onSelect(index)
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(colors[index % colors.count].opacity(
                                        index == selectedIndex ? 0.72 : 0.42
                                    ))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(
                                                index == selectedIndex ? Color.primary : Color.white.opacity(0.45),
                                                lineWidth: index == selectedIndex ? 2 : 1
                                            )
                                    }
                                    .overlay(alignment: .leading) {
                                        if width > 65 && height > 18 {
                                            Text("\(index + 1): \(SamplerNoteNames.name(zone.rootNote))")
                                                .font(.caption2.weight(.medium))
                                                .foregroundColor(.primary)
                                                .lineLimit(1).padding(.horizontal, 5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .frame(width: width, height: height)
                            .offset(
                                x: CGFloat(zone.lowestNote) * keyWidth,
                                y: CGFloat(127 - Int(zone.highestVelocity)) * velocityHeight / 127
                            )
                            .help("\(zone.sampleURL.lastPathComponent): \(SamplerNoteNames.name(zone.lowestNote))–\(SamplerNoteNames.name(zone.highestNote)), velocity \(zone.lowestVelocity)–\(zone.highestVelocity)")
                        }
                    }
                    .frame(width: mapWidth, height: velocityHeight)

                    HStack(spacing: 0) {
                        ForEach(0..<128, id: \.self) { note in
                            Rectangle()
                                .fill(SamplerNoteNames.isBlack(note)
                                      ? Color(white: 0.2)
                                      : Color(white: 0.88))
                                .overlay {
                                    if note % 12 == 0 {
                                        Text(SamplerNoteNames.name(UInt8(note)))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(.black)
                                    }
                                }
                                .overlay(Rectangle().stroke(.gray.opacity(0.35), lineWidth: 0.5))
                                .frame(width: keyWidth, height: keyboardHeight)
                                .id(note)
                        }
                    }
                }
                .frame(width: mapWidth)
            }
            .onAppear {
                DispatchQueue.main.async {
                    reader.scrollTo(60, anchor: .center)
                }
            }
        }
    }
}

private enum SamplerNoteNames {
    static func isBlack(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    static func name(_ note: UInt8) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F",
                     "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}
