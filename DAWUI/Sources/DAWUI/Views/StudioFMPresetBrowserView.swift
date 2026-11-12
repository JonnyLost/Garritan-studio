import SwiftUI
import DAWCore

/// Local native preset library. All file I/O occurs on the MainActor when
/// opening, saving or deleting. It never touches AVAudioEngine's render block.
/// "Load" updates the actual synthesizer and embedded project patch together.
public struct StudioFMPresetBrowserView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    public let trackID: TrackID

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCategory = "all"
    @State private var userPresets: [StudioFMPreset] = []
    @State private var skippedFiles: [String] = []
    @State private var selectedID: String?
    @State private var showSaveSheet = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private let store = StudioFMPresetStore()

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var library: [StudioFMPreset] {
        (StudioFMFactoryLibrary.presets + userPresets).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var filtered: [StudioFMPreset] {
        library.filter { preset in
            let matchesCategory = selectedCategory == "all" ||
                                  preset.category.rawValue == selectedCategory
            let matchesSearch = searchText.isEmpty ||
                preset.name.localizedCaseInsensitiveContains(searchText) ||
                preset.summary.localizedCaseInsensitiveContains(searchText) ||
                preset.category.title.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesSearch
        }
    }

    private var selectedPreset: StudioFMPreset? {
        library.first(where: { $0.id == selectedID })
    }

    private var currentPatch: StudioFMPatch {
        viewModel.project.track(withID: trackID)?.studioFMPatch
            ?? StudioFMPatch()
    }

    private var loadedID: String? {
        viewModel.project.track(withID: trackID)?.studioFMPresetID
    }

    private var trackName: String {
        viewModel.project.track(withID: trackID)?.name ?? "Instrument Track"
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.cyan)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("STUDIO FM · PRESET LIBRARY")
                        .font(.headline)
                    Text("32 original factory sounds · save and recall your own patches")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save Current Sound…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search presets", text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search Studio FM presets")
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(9)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))

                    Picker("Category", selection: $selectedCategory) {
                        Text("All categories").tag("all")
                        ForEach(StudioFMPresetCategory.allCases) { category in
                            Text(category.title).tag(category.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    List {
                        Section("FACTORY SOUNDS") {
                            ForEach(filtered.filter { $0.origin == .factory }) { preset in
                                row(for: preset)
                            }
                        }
                        Section("MY PRESETS") {
                            if filtered.filter({ $0.origin == .user }).isEmpty {
                                Text(userPresets.isEmpty
                                     ? "Save your first sound to create a preset."
                                     : "No matching user presets.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(filtered.filter { $0.origin == .user }) { preset in
                                row(for: preset)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .padding(12)
                .frame(minWidth: 330, idealWidth: 370, maxWidth: 440)
                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    if let preset = selectedPreset {
                        HStack {
                            Text(preset.category.title.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.cyan)
                            Spacer()
                            Label(preset.origin == .factory ? "Factory" : "My Preset",
                                  systemImage: preset.origin == .factory ? "lock" : "person.crop.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Text(preset.name)
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        Text(preset.summary.isEmpty ? "Custom four-operator FM sound." : preset.summary)
                            .font(.body).foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SOUND CHARACTER")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 9) {
                                soundValue("Algorithm", preset.patch, .algorithm)
                                soundValue("OP1 Ratio", preset.patch, .op1Ratio)
                                soundValue("OP2 Ratio", preset.patch, .op2Ratio)
                            }
                            Text(StudioFMAlgorithm(
                                    rawValue: Int(preset.patch.value(for: .algorithm))
                                 )?.description ?? "Original four-operator FM sound")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 10)

                        if preset.id == loadedID {
                            Label("Loaded on \(trackName)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                        }

                        HStack(spacing: 10) {
                            Button {
                                load(preset)
                            } label: {
                                Label("Load on Track", systemImage: "arrow.down.to.line")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)

                            Button {
                                viewModel.playbackEngine.playTestNote(on: trackID)
                            } label: {
                                Label("Audition Loaded C4", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            if preset.origin == .user {
                                Button(role: .destructive) {
                                    confirmDelete = true
                                } label: {
                                    Label("Delete Preset", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        Spacer()
                        ContentUnavailableView("Choose a Sound",
                            systemImage: "waveform.path",
                            description: Text("Select a factory sound or one of your saved patches."))
                        Spacer()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
            }

            if let errorMessage {
                feedback(errorMessage, isError: true)
            } else if !skippedFiles.isEmpty {
                feedback("\(skippedFiles.count) unreadable user preset file(s) were skipped.", isError: true)
            } else if let infoMessage {
                feedback(infoMessage, isError: false)
            }
        }
        .frame(minWidth: 880, minHeight: 570)
        .onAppear(perform: reload)
        .sheet(isPresented: $showSaveSheet) {
            StudioFMPresetSaveView { name, description, category in
                save(name: name, summary: description, category: category)
            } onCancel: {
                showSaveSheet = false
            }
        }
        .confirmationDialog(
            "Delete this user preset?",
            isPresented: $confirmDelete
        ) {
            Button("Delete Preset", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("The sound remains intact in any project tracks where it was loaded.")
        }
    }

    private func row(for preset: StudioFMPreset) -> some View {
        Button {
            selectedID = preset.id
            errorMessage = nil
            infoMessage = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: preset.origin == .factory ? "waveform" : "person.crop.circle")
                    .foregroundStyle(preset.origin == .factory ? .cyan : .purple)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(preset.category.title).font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                if loadedID == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(selectedID == preset.id ? Color.accentColor.opacity(0.17) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func soundValue(_ name: String, _ patch: StudioFMPatch,
                            _ parameter: StudioFMParameter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(parameter.displayValue(patch.value(for: parameter)))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func feedback(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
            Text(message)
            Spacer()
            Button("Dismiss") {
                errorMessage = nil
                infoMessage = nil
                if isError { skippedFiles = [] }
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(isError ? Color.cyan : Color.green)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
    }

    private func load(_ preset: StudioFMPreset) {
        do {
            try viewModel.applyStudioFMPreset(preset, for: trackID)
            errorMessage = nil
            infoMessage = "Loaded \(preset.name) on \(trackName). Play or audition to hear it."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        do {
            let loaded = try store.loadUserPresets()
            userPresets = loaded.presets
            skippedFiles = loaded.skippedFiles
            errorMessage = nil
            if selectedID == nil {
                selectedID = loadedID ?? StudioFMFactoryLibrary.presets.first?.id
            }
            if !library.contains(where: { $0.id == selectedID }) {
                selectedID = StudioFMFactoryLibrary.presets.first?.id
            }
        } catch {
            errorMessage = "Could not read My Presets: \(error.localizedDescription)"
        }
    }

    private func save(name: String, summary: String,
                      category: StudioFMPresetCategory) -> String? {
        do {
            let saved = try store.save(name: name, summary: summary, category: category,
                                       patch: currentPatch)
            viewModel.markStudioFMPresetSaved(id: saved.id, for: trackID)
            showSaveSheet = false
            reload()
            selectedID = saved.id
            errorMessage = nil
            infoMessage = "Saved \(saved.name) in My Presets."
            return nil
        } catch {
            // Keep the save sheet open and report the error within it.
            return error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let preset = selectedPreset, preset.origin == .user else { return }
        do {
            try store.delete(preset)
            selectedID = nil
            reload()
            infoMessage = "Deleted \(preset.name) from My Presets. Project sounds are unchanged."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StudioFMPresetSaveView: View {
    let onSave: (String, String, StudioFMPresetCategory) -> String?
    let onCancel: () -> Void

    @State private var name = ""
    @State private var summary = ""
    @State private var category: StudioFMPresetCategory = .lead
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                Text("Save Studio FM Preset")
                    .font(.title2.weight(.semibold))
            }
            Text("Save this track's FM algorithm, operator envelopes, ratios and levels for other projects.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Preset name").font(.caption.weight(.medium))
                TextField("My FM Sound", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Preset name")
                Text("Category").font(.caption.weight(.medium))
                Picker("Category", selection: $category) {
                    ForEach(StudioFMPresetCategory.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                Text("Description").font(.caption.weight(.medium))
                TextField("Optional notes about this sound", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.cyan)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button {
                    saveError = onSave(name, summary, category)
                } label: {
                    Label("Save Preset", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          name.count > 80)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 305)
    }
}
