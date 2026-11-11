import SwiftUI
import DAWCore

/// Local native preset library. All file I/O occurs on the MainActor when
/// opening, saving or deleting. It never touches AVAudioEngine's render block.
/// "Load" updates the actual synthesizer and embedded project patch together.
public struct StudioAnalogPresetBrowserView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    public let trackID: TrackID

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCategory = "all"
    @State private var userPresets: [StudioAnalogPreset] = []
    @State private var skippedFiles: [String] = []
    @State private var selectedID: String?
    @State private var showSaveSheet = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private let store = StudioAnalogPresetStore()

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var library: [StudioAnalogPreset] {
        (StudioAnalogFactoryLibrary.presets + userPresets).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var filtered: [StudioAnalogPreset] {
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

    private var selectedPreset: StudioAnalogPreset? {
        library.first(where: { $0.id == selectedID })
    }

    private var currentPatch: StudioAnalogPatch {
        viewModel.project.track(withID: trackID)?.studioAnalogPatch
            ?? StudioAnalogPatch()
    }

    private var loadedID: String? {
        viewModel.project.track(withID: trackID)?.studioAnalogPresetID
    }

    private var trackName: String {
        viewModel.project.track(withID: trackID)?.name ?? "Instrument Track"
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("STUDIO ANALOG · PRESET LIBRARY")
                        .font(.headline)
                    Text("24 original factory sounds · save and recall your own patches")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save Current Sound…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
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
                            .accessibilityLabel("Search Studio Analog presets")
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
                        ForEach(StudioAnalogPresetCategory.allCases) { category in
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
                                .foregroundStyle(.orange)
                            Spacer()
                            Label(preset.origin == .factory ? "Factory" : "My Preset",
                                  systemImage: preset.origin == .factory ? "lock" : "person.crop.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Text(preset.name)
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        Text(preset.summary.isEmpty ? "Custom Studio Analog sound." : preset.summary)
                            .font(.body).foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SOUND CHARACTER")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 9) {
                                soundValue("Oscillator 1", preset.patch, .oscillator1Wave)
                                soundValue("Oscillator 2", preset.patch, .oscillator2Wave)
                                soundValue("Filter", preset.patch, .filterCutoff)
                            }
                            Text(preset.patch.connections == nil
                                 ? "Standard Studio Analog module routing"
                                 : "Includes custom modular cable routing")
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
                            .tint(.orange)

                            Button {
                                viewModel.playbackEngine.playTestNote(on: trackID)
                            } label: {
                                Label("Audition C4", systemImage: "play.fill")
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
                            systemImage: "waveform",
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
            StudioAnalogPresetSaveView { name, description, category in
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

    private func row(for preset: StudioAnalogPreset) -> some View {
        Button {
            selectedID = preset.id
            errorMessage = nil
            infoMessage = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: preset.origin == .factory ? "waveform" : "person.crop.circle")
                    .foregroundStyle(preset.origin == .factory ? .orange : .cyan)
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

    private func soundValue(_ name: String, _ patch: StudioAnalogPatch,
                            _ parameter: StudioAnalogParameter) -> some View {
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
        .foregroundStyle(isError ? Color.orange : Color.green)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
    }

    private func load(_ preset: StudioAnalogPreset) {
        do {
            try viewModel.applyStudioAnalogPreset(preset, for: trackID)
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
                selectedID = loadedID ?? StudioAnalogFactoryLibrary.presets.first?.id
            }
            if !library.contains(where: { $0.id == selectedID }) {
                selectedID = StudioAnalogFactoryLibrary.presets.first?.id
            }
        } catch {
            errorMessage = "Could not read My Presets: \(error.localizedDescription)"
        }
    }

    private func save(name: String, summary: String,
                      category: StudioAnalogPresetCategory) {
        do {
            let saved = try store.save(name: name, summary: summary, category: category,
                                       patch: currentPatch)
            viewModel.markStudioAnalogPresetSaved(id: saved.id, for: trackID)
            showSaveSheet = false
            reload()
            selectedID = saved.id
            errorMessage = nil
            infoMessage = "Saved \(saved.name) in My Presets."
        } catch {
            // Keep the save sheet open so the user can correct the name.
            errorMessage = error.localizedDescription
            showSaveSheet = false
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

private struct StudioAnalogPresetSaveView: View {
    let onSave: (String, String, StudioAnalogPresetCategory) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var summary = ""
    @State private var category: StudioAnalogPresetCategory = .lead

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Save Studio Analog Preset")
                    .font(.title2.weight(.semibold))
            }
            Text("Save a reusable copy of this track's sound, controls and modular patch cables.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Preset name").font(.caption.weight(.medium))
                TextField("My Analog Sound", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Preset name")
                Text("Category").font(.caption.weight(.medium))
                Picker("Category", selection: $category) {
                    ForEach(StudioAnalogPresetCategory.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                Text("Description").font(.caption.weight(.medium))
                TextField("Optional notes about this sound", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button {
                    onSave(name, summary, category)
                } label: {
                    Label("Save Preset", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          name.count > 80)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 305)
    }
}
