import SwiftUI
import AppKit
import DAWCore

/// The application command opens this sheet on the owning Studio window.
/// Keeping this as a view modifier avoids making MainWindowView's already
/// large SwiftUI expression even harder for the macOS compiler to type-check.
public struct StudioExportSheetModifier: ViewModifier {
    @ObservedObject private var viewModel: ProjectViewModel
    @State private var showingExport = false

    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showStudioExport)) { _ in
                if !showingExport { showingExport = true }
            }
            .sheet(isPresented: $showingExport) {
                StudioExportView(viewModel: viewModel) {
                    showingExport = false
                }
            }
    }
}

private struct EditableStem: Identifiable {
    let id: UUID
    var name: String
    var trackIDs: Set<TrackID>

    init(name: String, trackIDs: Set<TrackID>) {
        self.id = UUID()
        self.name = name
        self.trackIDs = trackIDs
    }

    var exportStem: StudioExportStem {
        StudioExportStem(id: id, name: name,
                         trackIDs: Array(trackIDs))
    }
}

/// One destination folder, four export modes, family/individual selection,
/// PCM format and wet-tail options. The export UI never edits a track's
/// actual mute, solo, clip content, or instrument preset.
public struct StudioExportView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    @StateObject private var coordinator = StudioExportCoordinator()
    @State private var mode: StudioExportMode = .stereoMix
    @State private var selectedTracks: Set<TrackID>
    @State private var stems: [EditableStem]
    @State private var folder: URL?
    @State private var bitDepth: Int = 24
    @State private var tailSeconds: Double = 3
    @State private var errorMessage: String?
    @State private var completed = false
    @State private var exportTask: Task<Void, Never>?
    private let close: () -> Void

    public init(viewModel: ProjectViewModel, close: @escaping () -> Void) {
        self.viewModel = viewModel
        self.close = close
        _selectedTracks = State(initialValue: Set(viewModel.project.tracks.map(\.id)))
        _stems = State(initialValue:
            StudioExportPlan.groupsByFamily(viewModel.project).map {
                EditableStem(name: $0.name, trackIDs: Set($0.trackIDs))
            }
        )
    }

    private var families: [StudioExportStem] {
        StudioExportPlan.groupsByFamily(viewModel.project)
    }

    private var exportSettings: StudioExportSettings {
        StudioExportSettings(
            mode: mode, selectedTrackIDs: Array(selectedTracks),
            stems: stems.map(\.exportStem), tailSeconds: tailSeconds,
            bitDepth: bitDepth
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export Studio")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Stereo/mono mixes, independent tracks, or custom orchestral stems")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { close() }
                    .disabled(coordinator.isExporting)
            }
            HStack(spacing: 16) {
                Picker("Export", selection: $mode) {
                    ForEach(StudioExportMode.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 270)
                Picker("PCM depth", selection: $bitDepth) {
                    Text("16-bit WAV").tag(16)
                    Text("24-bit WAV").tag(24)
                }
                .frame(width: 175)
                Spacer()
            }
            HStack {
                Text("Reverb / release tail")
                Slider(value: $tailSeconds, in: 0...15, step: 0.5)
                Text(String(format: "%.1f s", tailSeconds))
                    .frame(width: 55, alignment: .trailing)
                    .monospacedDigit()
            }
            .font(.caption)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch mode {
                    case .stereoMix, .monoMix:
                        Text("One complete \(mode == .monoMix ? "mono" : "stereo") mix. Existing channel levels, inserts, pans and Hall sends are rendered through Studio's master output.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    case .individualTracks:
                        Text("Select the channels to export as separate stereo WAV files.")
                            .font(.subheadline)
                        HStack {
                            Button("Select All") {
                                selectedTracks = Set(viewModel.project.tracks.map(\.id))
                            }
                            Button("Clear") { selectedTracks.removeAll() }
                        }
                        .buttonStyle(.borderless)
                        ForEach(viewModel.project.tracks) { track in
                            trackSelection(track, in: Binding(
                                get: { selectedTracks.contains(track.id) },
                                set: { value in
                                    if value { selectedTracks.insert(track.id) }
                                    else { selectedTracks.remove(track.id) }
                                }
                            ))
                        }
                    case .customStems:
                        Text("Each stem can combine complete families with any individual channels. Overlap between different stems is allowed.")
                            .font(.subheadline)
                        ForEach(stems.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 12) {
                                    TextField("Stem name", text: $stems[index].name)
                                        .textFieldStyle(.roundedBorder)
                                    Menu("Add Family") {
                                        ForEach(families) { family in
                                            Button(family.name) {
                                                stems[index].trackIDs.formUnion(family.trackIDs)
                                            }
                                        }
                                    }
                                    Button(role: .destructive) {
                                        stems.remove(at: index)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .help("Remove this stem group")
                                }
                                ForEach(viewModel.project.tracks) { track in
                                    trackSelection(track, in: Binding(
                                        get: { stems[index].trackIDs.contains(track.id) },
                                        set: { value in
                                            if value { stems[index].trackIDs.insert(track.id) }
                                            else { stems[index].trackIDs.remove(track.id) }
                                        }
                                    ))
                                }
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        Button {
                            stems.append(EditableStem(
                                name: "New Stem \(stems.count + 1)",
                                trackIDs: []
                            ))
                        } label: {
                            Label("Add Stem Group", systemImage: "plus.circle")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 330)

            Divider()

            HStack {
                Button {
                    chooseFolder()
                } label: {
                    Label(folder?.lastPathComponent ?? "Choose Export Folder…",
                          systemImage: "folder")
                }
                .disabled(coordinator.isExporting)
                if let folder {
                    Text(folder.path)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if coordinator.isExporting {
                    Button("Cancel Export") {
                        exportTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }
                Button("Export") {
                    beginExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isExporting || folder == nil ||
                          (mode == .individualTracks && selectedTracks.isEmpty))
            }
            if coordinator.isExporting {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: coordinator.progress)
                    Text(coordinator.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if completed {
                Label("All WAV files exported successfully. You can find them in the selected folder.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text("Real-time bounce at Studio's current audio-device sample rate. Tracks routed through the shared V-Rack and variable tempo maps are not yet supported.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 580)
    }

    private func trackSelection(_ track: Track, in binding: Binding<Bool>) -> some View {
        HStack {
            Toggle(track.name, isOn: binding)
            Spacer(minLength: 10)
            Text(StudioExportPlan.family(for: track))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose where Studio should save the exported WAV files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }
        folder = panel.url
    }

    private func beginExport() {
        guard let folder else { return }
        errorMessage = nil
        completed = false
        let settings = exportSettings
        exportTask = Task {
            defer { exportTask = nil }
            do {
                _ = try await coordinator.export(
                    projectViewModel: viewModel,
                    settings: settings, to: folder
                )
                completed = true
            } catch is CancellationError {
                errorMessage = "Export canceled. No incomplete WAV files were committed."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
