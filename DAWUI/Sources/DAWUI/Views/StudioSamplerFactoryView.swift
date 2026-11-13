import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import DAWCore

/// The missing in-DAW loop: capture from the existing safe audio input tap,
/// prepare samples offline, label their note/velocity/mic/articulation, then
/// pass the prepared takes into the sampler's editable mapping draft.
public struct StudioSamplerFactoryView: View {
    @ObservedObject public var viewModel: ProjectViewModel
    public let trackID: TrackID
    public let onAdd: ([StudioSamplerFactoryTake]) -> Void

    @ObservedObject private var recorder: AudioRecorder
    @Environment(\.dismiss) private var dismiss

    @State private var note = 60
    @State private var velocity = 96
    @State private var microphoneID = 0
    @State private var articulation = "Sustain"
    @State private var releaseTrigger = false
    @State private var recordTransition = false
    @State private var legatoFrom = 59
    @State private var trimSilence = true
    @State private var normalize = true
    @State private var thresholdDB = -55.0
    @State private var fadeInMS = 3.0
    @State private var fadeOutMS = 15.0

    @State private var pending: [StudioSamplerFactoryTake] = []
    @State private var ownedFiles: [URL] = []
    @State private var activeCapture: StudioSamplerFactoryTake?
    @State private var preparing = false
    @State private var installing = false
    @State private var importPicker = false
    @State private var error: String?
    @State private var notice: String?
    @State private var handedOff = false

    public init(viewModel: ProjectViewModel, trackID: TrackID,
                onAdd: @escaping ([StudioSamplerFactoryTake]) -> Void) {
        self.viewModel = viewModel
        self.trackID = trackID
        self.onAdd = onAdd
        self._recorder = ObservedObject(wrappedValue: viewModel.audioRecorder)
    }

    private var busy: Bool { preparing || installing || activeCapture != nil }

    private var currentTake: StudioSamplerFactoryTake {
        StudioSamplerFactoryTake(
            source: FileManager.default.temporaryDirectory,
            rootNote: UInt8(clamping: note),
            velocity: UInt8(clamping: velocity),
            microphoneID: UInt8(clamping: microphoneID),
            articulation: articulation,
            releaseTrigger: releaseTrigger,
            legatoFromNote: recordTransition ? UInt8(clamping: legatoFrom) : nil
        )
    }

    private var processing: StudioSamplerFactoryProcessor.Settings {
        .init(trimSilence: trimSilence,
              silenceThresholdDB: Float(thresholdDB),
              normalize: normalize, targetPeakDB: -1,
              fadeInMilliseconds: fadeInMS,
              fadeOutMilliseconds: fadeOutMS)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Studio Instrument Factory", systemImage: "waveform.badge.mic")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(pending.count) prepared takes")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Close") { dismiss() }.disabled(busy)
            }
            Text("Record directly from Studio's existing audio input, or import your own audio. Clean it offline, label each take, and add everything to your editable sampler mapping. No commercial sampling software is needed.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Capture Labels", systemImage: "tag")
                        .font(.headline)
                    Stepper("Root MIDI note: \(note)", value: $note, in: 0...127)
                    Stepper("Recorded velocity: \(velocity)", value: $velocity, in: 1...127)
                    Picker("Mic position", selection: $microphoneID) {
                        Text("Close / Default").tag(0)
                        Text("Main / Tree").tag(1)
                        Text("Room").tag(2)
                        Text("Spot").tag(3)
                    }
                    TextField("Articulation (Sustain, Pizzicato…)", text: $articulation)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Release-trigger recording", isOn: $releaseTrigger)
                        .onChange(of: releaseTrigger) { _, newValue in
                            if newValue { recordTransition = false }
                        }
                    Toggle("Recorded legato interval", isOn: $recordTransition)
                        .onChange(of: recordTransition) { _, newValue in
                            if newValue { releaseTrigger = false }
                        }
                    if recordTransition {
                        Stepper("From MIDI note: \(legatoFrom)", value: $legatoFrom,
                                in: 0...127)
                        Text("Record the actual movement from the From note to the root note. Both notes must differ.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Use the same note, mic and articulation with multiple velocities to build dynamic layers.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(busy)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Sample Preparation", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Toggle("Trim silence around recording", isOn: $trimSilence)
                    HStack {
                        Text("Threshold")
                        Slider(value: $thresholdDB, in: -75 ... -25)
                        Text("\(Int(thresholdDB)) dB").monospacedDigit()
                    }
                    .disabled(!trimSilence)
                    Toggle("Normalize to -1 dB peak", isOn: $normalize)
                    HStack {
                        Text("Fade in")
                        Slider(value: $fadeInMS, in: 0...50)
                        Text("\(Int(fadeInMS)) ms").monospacedDigit()
                    }
                    HStack {
                        Text("Fade out")
                        Slider(value: $fadeOutMS, in: 0...120)
                        Text("\(Int(fadeOutMS)) ms").monospacedDigit()
                    }
                    Text("The original recording is never modified. Studio creates an edited WAV copy; loop and trim markers can still be adjusted nondestructively in Mapping.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Label("Audio Input", systemImage: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: Double(min(1, recorder.inputLevel)), total: 1)
                    Text(String(format: "Input %.0f%% · Recorded %.1f s",
                                min(1, recorder.inputLevel) * 100,
                                recorder.recordingDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack {
                        if activeCapture != nil {
                            Button {
                                finishRecording()
                            } label: {
                                Label("Stop & Prepare", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Discard", role: .destructive) {
                                recorder.cancelRecording()
                                activeCapture = nil
                            }
                        } else {
                            Button {
                                startRecording()
                            } label: {
                                Label("Record Sample", systemImage: "record.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || !currentTake.isValid ||
                                      viewModel.isRecording || recorder.isRecording)
                        }
                        Button("Import Audio…") { importPicker = true }
                            .disabled(busy || !currentTake.isValid)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(preparing || installing)
            }
            Divider()
            HStack {
                Label("Prepared Takes", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                if preparing { ProgressView("Preparing recordings…").controlSize(.small) }
            }
            List {
                ForEach(pending) { take in
                    HStack {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(take.source.lastPathComponent).lineLimit(1)
                            Text("MIDI \(take.rootNote) · V\(take.velocity) · Mic \(take.microphoneID) · \(take.normalizedArticulation.isEmpty ? "Sustain" : take.normalizedArticulation)\(take.legatoFromNote == nil ? "" : " · Legato from \(take.legatoFromNote!)")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pending.removeAll { $0.id == take.id }
                            if ownedFiles.contains(take.source) {
                                try? FileManager.default.removeItem(at: take.source)
                                ownedFiles.removeAll { $0 == take.source }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(busy)
                    }
                }
            }
            .frame(minHeight: 130)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    installStarterSounds()
                } label: {
                    Label(installing ? "Creating…" : "Install 4 Original Studio Sounds",
                          systemImage: "sparkles")
                }
                .disabled(busy)
                Spacer()
                Text("Samples are added to the mapping draft; press Apply Mapping to make them playable.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Add \(pending.count) Takes to Instrument") {
                    guard !pending.isEmpty else { return }
                    handedOff = true
                    onAdd(pending)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || pending.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 690)
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $importPicker, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { selection in
            switch selection {
            case .success(let urls): prepareFiles(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .onDisappear {
            if activeCapture != nil {
                recorder.cancelRecording()
                activeCapture = nil
            }
            if !handedOff {
                for url in ownedFiles { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func startRecording() {
        guard !busy && !viewModel.isRecording && !recorder.isRecording,
              currentTake.isValid else { return }
        error = nil
        let labels = currentTake
        Task { @MainActor in
            let allowed = await recorder.requestMicrophonePermission()
            guard allowed else {
                error = "Allow microphone access in macOS Privacy & Security to record."
                return
            }
            guard !viewModel.isRecording && !recorder.isRecording else {
                error = "Another Studio recording is already in progress."
                return
            }
            do {
                let url = try recorder.startRecording(
                    trackID: trackID,
                    filename: "StudioInstrumentFactory-\(UUID().uuidString)")
                var take = labels
                take.source = url
                activeCapture = take
                ownedFiles.append(url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard let take = activeCapture else { return }
        activeCapture = nil
        guard let result = recorder.stopRecording(), result.sampleCount > 256 else {
            error = recorder.lastRecordingError ??
                "Recording was empty or too short. Try a longer take."
            return
        }
        prepareFiles([result.fileURL], labels: take)
    }

    private func prepareFiles(_ files: [URL],
                              labels: StudioSamplerFactoryTake? = nil) {
        guard !preparing && !files.isEmpty else { return }
        preparing = true
        error = nil
        notice = nil
        let captured = labels ?? currentTake
        let config = processing
        Task { @MainActor in
            defer { preparing = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    var results: [StudioSamplerFactoryTake] = []
                    do {
                        for url in files {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let output = FileManager.default.temporaryDirectory
                                .appendingPathComponent(
                                    "StudioFactoryPrepared-\(UUID().uuidString).wav")
                            let report = try StudioSamplerFactoryProcessor.prepare(
                                source: url, destination: output, settings: config)
                            var take = captured
                            take = StudioSamplerFactoryTake(
                                source: report.url, rootNote: take.rootNote,
                                velocity: take.velocity, microphoneID: take.microphoneID,
                                articulation: take.articulation,
                                releaseTrigger: take.releaseTrigger,
                                legatoFromNote: take.legatoFromNote)
                            results.append(take)
                        }
                        return results
                    } catch {
                        for take in results {
                            try? FileManager.default.removeItem(at: take.source)
                        }
                        throw error
                    }
                }.value
                pending.append(contentsOf: prepared)
                ownedFiles.append(contentsOf: prepared.map(\.source))
                notice = "Prepared \(prepared.count) recording(s). Capture more layers or add these takes."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func installStarterSounds() {
        installing = true
        error = nil
        notice = nil
        Task { @MainActor in
            defer { installing = false }
            do {
                let added = try await Task.detached(priority: .utility) {
                    try StudioSamplerFactoryStarterLibrary.install()
                }.value
                notice = added.isEmpty
                    ? "Original Studio starter instruments are already installed. Browse Instrument Library to load them."
                    : "Installed \(added.count) editable original instruments. Open Instrument Library to load one."
            } catch {
                error = error.localizedDescription
            }
        }
    }
}
