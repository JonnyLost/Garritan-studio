import SwiftUI
import DAWCore

/// Audio Unit Auto Sampler lives beside the existing recording/import factory.
/// It never modifies the source plug-in or the live DAW audio graph. A finished
/// instrument can be loaded here, or later from Studio's Instrument Library.
public struct StudioAutoSamplerView: View {
    @ObservedObject public var viewModel: ProjectViewModel
    public let trackID: TrackID
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [StudioAutoSamplerCapture.Source] = []
    @State private var selectedSourceID = ""
    @State private var presets: [StudioAutoSamplerCapture.Preset] = []
    @State private var selectedPreset: Int?
    @State private var coverage: StudioAutoSamplerCapture.Coverage = .standard
    @State private var name = "My Sampled Instrument"
    @State private var sustainSeconds = 1.5
    @State private var releaseSeconds = 0.65
    @State private var isCapturing = false
    @State private var isLoadingPresets = false
    @State private var errorMessage: String?
    @State private var result: StudioAutoSamplerCapture.Result?
    @State private var captureTask: Task<Void, Never>?

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var selectedSource: StudioAutoSamplerCapture.Source? {
        sources.first { $0.id == selectedSourceID }
    }

    private var options: StudioSynthSamplerCapture.Options {
        var setting = coverage.options
        setting.sustainSeconds = sustainSeconds
        setting.releaseSeconds = releaseSeconds
        return setting
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Studio Auto Sampler", systemImage: "pianokeys")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(isCapturing)
            }
            Text("Capture a compatible, installed Audio Unit instrument as independent WAV samples, map the keys and velocities, and save a native Studio instrument. Studio uses a separate offline engine; the current project keeps playing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Audio Unit instrument", selection: $selectedSourceID) {
                    Text("Choose an instrument…").tag("")
                    ForEach(sources) { source in
                        Text("\(source.vendor) — \(source.name)").tag(source.id)
                    }
                }
                .frame(maxWidth: .infinity)
                .onChange(of: selectedSourceID) { _, _ in refreshPresets() }
                Button {
                    sources = StudioAutoSamplerCapture.availableSources()
                    if selectedSource == nil { selectedSourceID = "" }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isCapturing)
            }
            .disabled(isCapturing)

            if sources.isEmpty {
                Label("No registered Audio Unit Music Device instruments found. Install and register a compatible Audio Unit to use this capture mode.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            HStack {
                Picker("Factory preset", selection: $selectedPreset) {
                    Text("Default sound").tag(nil as Int?)
                    ForEach(presets) { preset in
                        Text(preset.name).tag(preset.number as Int?)
                    }
                }
                .disabled(isCapturing || isLoadingPresets || selectedSource == nil)
                if isLoadingPresets { ProgressView().controlSize(.small) }
                Spacer()
            }

            Text("Only Audio Unit factory presets are selectable in this milestone. Plug-in editors, saved custom states, and real-time capture are planned separately.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("New instrument name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isCapturing)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Coverage", selection: $coverage) {
                        ForEach(StudioAutoSamplerCapture.Coverage.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("\(options.rootNotes.count) notes × \(options.velocities.count) velocities = \(options.rootNotes.count * options.velocities.count) recordings")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: "Held note: %.1f seconds", sustainSeconds))
                    Slider(value: $sustainSeconds, in: 0.1...5, step: 0.1)
                    Text(String(format: "Release tail: %.1f seconds", releaseSeconds))
                    Slider(value: $releaseSeconds, in: 0.1...3, step: 0.1)
                }
                .font(.caption)
            }
            .disabled(isCapturing)

            if isCapturing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Capturing Audio Unit recordings and packaging instrument…")
                        .font(.caption)
                    Spacer()
                    Button("Cancel") { captureTask?.cancel() }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let result {
                Divider()
                Label("Saved \(result.takeCount) recordings to \(result.packageURL.lastPathComponent)",
                      systemImage: "checkmark.circle")
                    .font(.callout)
                HStack {
                    Button("Load as Sampler on This Track") {
                        do {
                            try viewModel.loadStudioSampler(for: trackID,
                                                            patch: result.patch)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [result.packageURL])
                    }
                }
            }

            Spacer(minLength: 0)
            HStack {
                Text("Use only instruments and sample content you are permitted to capture.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Capture to Instrument Library") { beginCapture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCapturing || selectedSource == nil ||
                              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !options.isValid)
            }
        }
        .padding(22)
        .frame(minWidth: 670, minHeight: 510)
        .interactiveDismissDisabled(isCapturing)
        .onAppear { sources = StudioAutoSamplerCapture.availableSources() }
        .onDisappear { captureTask?.cancel() }
    }

    private func refreshPresets() {
        presets = []
        selectedPreset = nil
        errorMessage = nil
        guard let source = selectedSource else {
            isLoadingPresets = false
            return
        }
        isLoadingPresets = true
        Task { @MainActor in
            do {
                let found = try await StudioAutoSamplerCapture.presets(for: source)
                if selectedSourceID == source.id { presets = found }
            } catch {
                if selectedSourceID == source.id {
                    errorMessage = "Could not inspect factory presets: \(error.localizedDescription)"
                }
            }
            if selectedSourceID == source.id { isLoadingPresets = false }
        }
    }

    private func beginCapture() {
        guard let source = selectedSource, options.isValid,
              !isCapturing else { return }
        let sourceName = name
        let captureOptions = options
        let chosenPreset = selectedPreset
        result = nil
        errorMessage = nil
        isCapturing = true
        captureTask = Task.detached(priority: .utility) {
            do {
                let output = try await StudioAutoSamplerCapture.capture(
                    source: source, name: sourceName, options: captureOptions,
                    presetNumber: chosenPreset)
                await MainActor.run {
                    self.result = output
                    self.isCapturing = false
                    self.captureTask = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isCapturing = false
                    self.captureTask = nil
                }
            }
        }
    }
}
