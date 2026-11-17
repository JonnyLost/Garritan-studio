import SwiftUI
import AudioToolbox
import DAWCore

/// Audio Unit Auto Sampler lives beside the existing recording/import factory.
/// It never modifies the source plug-in or the live DAW audio graph. A finished
/// instrument can be loaded here, or later from Studio's Instrument Library.
public struct StudioAutoSamplerView: View {
    private enum SoundSourceMode: String, CaseIterable {
        case loaded = "Configured in Studio"
        case installed = "Installed Audio Unit"
    }

    private struct LoadedSource: Identifiable {
        let id: String
        let title: String
        let pluginID: UUID
        let source: StudioAutoSamplerCapture.Source
    }

    @ObservedObject public var viewModel: ProjectViewModel
    public let trackID: TrackID
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [StudioAutoSamplerCapture.Source] = []
    @State private var soundSourceMode: SoundSourceMode = .loaded
    @State private var selectedLoadedID = ""
    @State private var selectedSourceID = ""
    @State private var presets: [StudioAutoSamplerCapture.Preset] = []
    @State private var selectedPreset: Int?
    @State private var coverage: StudioAutoSamplerCapture.Coverage = .standard
    @State private var dynamicsMode: StudioAutoSamplerExpression.Mode = .velocity
    @State private var fixedNoteVelocity = 100
    @State private var sendCC11 = false
    @State private var sourceCC11 = 127
    @State private var captureArticulations = false
    @State private var sustainKeyswitch = 24
    @State private var alternateKeyswitch = 25
    @State private var alternateName = "Staccato"
    @State private var midiChannel = 1
    @State private var customRange = false
    @State private var lowestNote = 36
    @State private var highestNote = 84
    @State private var semitoneStep = 12
    @State private var limitPlaybackToRange = true
    @State private var name = "My Sampled Instrument"
    @State private var sustainSeconds = 1.5
    @State private var releaseSeconds = 0.65
    @State private var autoLoopSustains = true
    @State private var captureReleaseTails = false
    @State private var isCapturing = false
    @State private var isLoadingPresets = false
    @State private var errorMessage: String?
    @State private var result: StudioAutoSamplerCapture.Result?
    @State private var captureTask: Task<Void, Never>?

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    /// Read only the actual loaded AU instances on tracks and in the V-Rack.
    /// Do not use cached preset data because it may predate the latest edits.
    private var loadedSources: [LoadedSource] {
        var items: [LoadedSource] = []
        for track in viewModel.project.tracks {
            guard let instrument = viewModel.playbackEngine.instrument(for: track.id),
                  case .auInstrument(let unit, let pluginID) = instrument,
                  viewModel.pluginHost.loadedPlugins[pluginID] != nil else { continue }
            let d = unit.audioComponentDescription
            guard d.componentType == kAudioUnitType_MusicDevice else { continue }
            let source = StudioAutoSamplerCapture.Source(
                type: d.componentType, subtype: d.componentSubType,
                manufacturer: d.componentManufacturer,
                name: track.instrumentSlot?.pluginID?.name ?? track.name,
                vendor: track.instrumentSlot?.pluginID?.manufacturer ?? "Audio Unit")
            items.append(LoadedSource(id: pluginID.uuidString,
                                      title: "Track: \(track.name) — \(source.name)",
                                      pluginID: pluginID, source: source))
        }
        for rack in viewModel.project.vRack.instruments {
            guard let instrument = viewModel.playbackEngine.rackInstrument(for: rack.id),
                  case .auInstrument(let unit, let pluginID) = instrument,
                  viewModel.pluginHost.loadedPlugins[pluginID] != nil else { continue }
            let d = unit.audioComponentDescription
            guard d.componentType == kAudioUnitType_MusicDevice else { continue }
            let source = StudioAutoSamplerCapture.Source(
                type: d.componentType, subtype: d.componentSubType,
                manufacturer: d.componentManufacturer,
                name: rack.pluginSlot.pluginID?.name ?? rack.name,
                vendor: rack.pluginSlot.pluginID?.manufacturer ?? "Audio Unit")
            items.append(LoadedSource(id: pluginID.uuidString,
                                      title: "V-Rack: \(rack.name) — \(source.name)",
                                      pluginID: pluginID, source: source))
        }
        return items.sorted { $0.title < $1.title }
    }

    private var selectedLoadedSource: LoadedSource? {
        loadedSources.first { $0.id == selectedLoadedID }
    }

    private var selectedSource: StudioAutoSamplerCapture.Source? {
        sources.first { $0.id == selectedSourceID }
    }

    private var captureSource: StudioAutoSamplerCapture.Source? {
        soundSourceMode == .loaded ? selectedLoadedSource?.source : selectedSource
    }

    private var samplingPlan: StudioAutoSamplerCapture.SamplingPlan {
        if customRange {
            return .init(coverage: coverage,
                         lowestNote: UInt8(clamping: lowestNote),
                         highestNote: UInt8(clamping: highestNote),
                         semitoneStep: UInt8(clamping: semitoneStep),
                         midiChannel: UInt8(clamping: midiChannel),
                         limitPlaybackToRange: limitPlaybackToRange)
        }
        return .init(coverage: coverage,
                     midiChannel: UInt8(clamping: midiChannel))
    }

    private var options: StudioSynthSamplerCapture.Options {
        samplingPlan.options(sustainSeconds: sustainSeconds,
                             releaseSeconds: releaseSeconds)
    }

    private var expressionConfiguration: StudioAutoSamplerExpression.Configuration {
        .init(mode: dynamicsMode,
              fixedNoteVelocity: UInt8(clamping: fixedNoteVelocity),
              sourceCC11: dynamicsMode == .cc1Layers || sendCC11
                  ? UInt8(clamping: sourceCC11) : nil)
    }

    private var articulationPlan: StudioAutoSamplerArticulations.Plan {
        .init(entries: captureArticulations ? [
            .init(name: "Sustain", sourceKeyswitch: UInt8(clamping: sustainKeyswitch)),
            .init(name: alternateName,
                  sourceKeyswitch: UInt8(clamping: alternateKeyswitch))
        ] : [], sourceChannel: UInt8(clamping: midiChannel))
    }

    private var fitsSampleZoneLimit: Bool {
        StudioAutoSamplerReleaseCapture.fitsZoneLimit(
            heldSampleCount: samplingPlan.sampleCount *
                (captureArticulations ? 2 : 1),
            includeReleases: captureReleaseTails) &&
        expressionConfiguration.canCaptureLayers(
            samplingPlan.velocities,
            captureReleaseTails: captureReleaseTails) &&
        articulationPlan.isValid(for: samplingPlan.rootNotes,
                                 velocities: samplingPlan.velocities,
                                 captureReleases: captureReleaseTails)
    }

    private var cc1CapturePositionsLabel: String {
        StudioAutoSamplerExpression.Configuration
            .cc1Centers(for: samplingPlan.velocities)
            .map { String($0) }.joined(separator: ", ")
    }

    private func noteLabel(_ number: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯",
                     "G", "G♯", "A", "A♯", "B"]
        return "\(names[number % 12])\(number / 12 - 1) · MIDI \(number)"
    }

    public var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Studio Auto Sampler", systemImage: "pianokeys")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(isCapturing)
            }
            Text("Capture an installed or configured Audio Unit as independent native samples. Choose velocity or CC1 dynamics, map the playable range, and save a Studio instrument without changing the live project.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()

            Picker("Sound source", selection: $soundSourceMode) {
                ForEach(SoundSourceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isCapturing)

            if soundSourceMode == .loaded {
                Picker("Loaded instrument", selection: $selectedLoadedID) {
                    Text("Choose a loaded instrument…").tag("")
                    ForEach(loadedSources) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                .disabled(isCapturing)
                if loadedSources.isEmpty {
                    Label("No Audio Unit instruments are currently loaded in a Studio track or V-Rack. Load and configure one first, or choose Installed Audio Unit.",
                          systemImage: "info.circle")
                        .font(.caption)
                } else {
                    Text("Samples the sound configured in the selected Studio plugin instance. Studio snapshots its current state and restores that state in a separate capture instance. The original stays untouched.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
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
                    Label("No registered Audio Unit Music Device instruments found.",
                          systemImage: "info.circle")
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
                Text("Installed Audio Unit mode captures the default or a published factory preset. For a custom sound, load and edit it on a Studio track or V-Rack first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            TextField("New instrument name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isCapturing)

            HStack(spacing: 12) {
                Picker("Source MIDI channel", selection: $midiChannel) {
                    ForEach(1...16, id: \.self) { channel in
                        Text("Channel \(channel)").tag(channel)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isCapturing)
                Text("Choose the channel containing the instrument program, especially for multitimbral ARIA instances.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Coverage", selection: $coverage) {
                        ForEach(StudioAutoSamplerCapture.Coverage.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("\(samplingPlan.rootNotes.count) notes × \(samplingPlan.velocities.count) velocities = \(samplingPlan.sampleCount) held recordings")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if captureReleaseTails {
                        Text("Up to \(samplingPlan.sampleCount * 2) total sampler zones, including note-off tails")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
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

            VStack(alignment: .leading, spacing: 9) {
                Toggle("Custom note range and sampling interval",
                       isOn: $customRange)
                    .onChange(of: customRange) { _, enabled in
                        if enabled {
                            let defaults = StudioAutoSamplerCapture.SamplingPlan(
                                coverage: coverage)
                            lowestNote = Int(defaults.lowestNote)
                            highestNote = Int(defaults.highestNote)
                            semitoneStep = Int(defaults.semitoneStep)
                        }
                    }
                if customRange {
                    HStack(spacing: 18) {
                        Stepper("Lowest: \(noteLabel(lowestNote))",
                                value: $lowestNote, in: 0...highestNote)
                        Stepper("Highest: \(noteLabel(highestNote))",
                                value: $highestNote, in: lowestNote...127)
                    }
                    Picker("Sample every", selection: $semitoneStep) {
                        ForEach([1, 2, 3, 4, 6, 12, 24], id: \.self) { distance in
                            Text("\(distance) semitone\(distance == 1 ? "" : "s")")
                                .tag(distance)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Only play within selected key range",
                           isOn: $limitPlaybackToRange)
                    if !samplingPlan.isValid {
                        Label("Too many samples (maximum 128), or an invalid note range. Increase the sampling interval or choose Quick/Standard coverage.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Preset note coverage. Enable custom range to limit sampling to the instrument's actual playable notes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isCapturing)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Capture source keyswitch articulations",
                       isOn: $captureArticulations)
                    .onChange(of: captureArticulations) { _, enabled in
                        if enabled { captureReleaseTails = false }
                    }
                if captureArticulations {
                    Text("Capture Sustain and one alternate playing technique from the same Audio Unit. Enter the source plugin's keyswitch MIDI notes; Studio builds its own native keyswitch map.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Stepper("Sustain source switch: \(sustainKeyswitch)",
                                value: $sustainKeyswitch, in: 0...127)
                        Stepper("Alternate source switch: \(alternateKeyswitch)",
                                value: $alternateKeyswitch, in: 0...127)
                    }
                    TextField("Alternate articulation name", text: $alternateName)
                    Text("Requires two distinct keyswitch notes outside the sampled root notes. Doubles the recordings and may exceed the 128-zone limit. Natural release tails are unavailable in multi-articulation mode until their native routing is articulation-aware.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !fitsSampleZoneLimit {
                        Label("Check keyswitch notes, articulation name and the 128-zone recording budget.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(isCapturing)

            VStack(alignment: .leading, spacing: 9) {
                Picker("Source dynamics", selection: $dynamicsMode) {
                    ForEach(StudioAutoSamplerExpression.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: dynamicsMode) { _, selected in
                    if selected == .cc1Layers { captureReleaseTails = false }
                }
                if dynamicsMode == .cc1Layers {
                    Text("Capture the source Audio Unit at fixed MIDI velocity while sweeping CC1 across the native sampler's dynamic layer centers. On playback, Studio crossfades these timbres using live CC1.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Stepper("Source note velocity: \(fixedNoteVelocity)",
                            value: $fixedNoteVelocity, in: 1...127)
                    Text("Source CC1 positions: \(cc1CapturePositionsLabel)")
                        .font(.caption.monospacedDigit())
                    if samplingPlan.velocities.count < 2 {
                        Label("Select Standard or Deep coverage: CC1 crossfading requires at least two dynamic layers.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Release-trigger capture is unavailable in CC1 mode until note-off samples can follow live dynamic-layer selection.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Record ordinary MIDI velocity layers, preserving the existing sampling behavior.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("Set a source CC11 reference level",
                           isOn: $sendCC11)
                }
                if dynamicsMode == .cc1Layers || sendCC11 {
                    Stepper("Source CC11 (expression): \(sourceCC11)",
                            value: $sourceCC11, in: 1...127)
                    Text("This level is recorded into each WAV. The finished Studio sampler retains independent live CC11 volume/expression control, starting at 127 to avoid double attenuation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isCapturing)

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Find sustain loops automatically",
                       isOn: $autoLoopSustains)
                Text("Studio examines only the held portion of each recording. Strong matches receive editable loop and crossfade markers; decaying, short, or uncertain sounds remain one-shots. The original WAVs are not changed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if autoLoopSustains && sustainSeconds < 0.8 {
                    Text("Held notes shorter than 0.8 seconds are preserved as one-shots.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .disabled(isCapturing)

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Capture natural note-off release samples",
                       isOn: $captureReleaseTails)
                    .disabled(dynamicsMode == .cc1Layers || captureArticulations)
                Text("Studio extracts the actual note-off portion of each offline recording. Audible tails become dedicated release-trigger zones; silent tails are skipped. This may nearly double instrument storage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if captureReleaseTails && !fitsSampleZoneLimit {
                    Label("Release samples require 64 or fewer held recordings to fit Studio's 128-zone instrument limit. Reduce the key or velocity coverage, or disable release capture.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                if result.articulationCount > 1 {
                    Label("\(result.articulationCount) keyswitched articulations mapped into the native instrument.",
                          systemImage: "pianokeys")
                        .font(.caption)
                }
                if result.dynamicsMode == .cc1Layers {
                    Label("CC1 dynamic layers captured; live CC1 crossfade and CC11 expression enabled.",
                          systemImage: "waveform.path")
                        .font(.caption)
                } else if let cc11 = result.sourceCC11 {
                    Text("Source expression CC11 set to \(cc11) during sampling; live CC11 remains adjustable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if result.releaseCount > 0 {
                    Text("\(result.releaseCount) natural release tails · \(result.releaseSkippedCount) silent or unsuitable tails skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if captureReleaseTails {
                    Text("No audible release tails found. The held samples remain usable without release triggers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if result.loopCount > 0 {
                    Text("\(result.loopCount) sustain loops with crossfades · \(result.loopSkippedCount) one-shot recordings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if autoLoopSustains && result.loopSkippedCount > 0 {
                    Text("No reliable sustain loops found. All recordings remain one-shots; you can edit loops in Sampler Mapping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .disabled(isCapturing || captureSource == nil ||
                              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !options.isValid || !samplingPlan.isValid ||
                              !fitsSampleZoneLimit)
            }
        }
        .padding(22)
        }
        .frame(minWidth: 670, minHeight: 510)
        .interactiveDismissDisabled(isCapturing)
        .onAppear {
            sources = StudioAutoSamplerCapture.availableSources()
            if let first = loadedSources.first {
                selectedLoadedID = first.id
            } else {
                soundSourceMode = .installed
            }
        }
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
        guard let source = captureSource, options.isValid,
              samplingPlan.isValid, fitsSampleZoneLimit,
              !isCapturing else { return }
        // Copy the actual, most recent state while still on Studio's host
        // control actor; no AU objects are passed into the detached capture.
        let currentSound: Data?
        if soundSourceMode == .loaded {
            guard let loaded = selectedLoadedSource else { return }
            do {
                let data = try viewModel.pluginHost.savePreset(pluginID: loaded.pluginID)
                _ = try StudioAutoSamplerCapture.validatedConfiguredState(data)
                currentSound = data
            } catch {
                errorMessage = "Could not snapshot the configured instrument: \(error.localizedDescription)"
                return
            }
        } else {
            currentSound = nil
        }
        let sourceName = name
        let captureOptions = options
        let selectedPlan = samplingPlan
        let loopEnabled = autoLoopSustains
        let captureExpression = expressionConfiguration
        let selectedArticulations = articulationPlan
        let includeReleases = captureReleaseTails
        let chosenPreset = soundSourceMode == .installed ? selectedPreset : nil
        result = nil
        errorMessage = nil
        isCapturing = true
        captureTask = Task.detached(priority: .utility) {
            do {
                let output = try await StudioAutoSamplerCapture.capture(
                    source: source, name: sourceName, options: captureOptions,
                    presetNumber: chosenPreset, configuredState: currentSound,
                    plan: selectedPlan, autoLoopSustains: loopEnabled,
                    captureReleaseTails: includeReleases,
                    expression: captureExpression,
                    articulations: selectedArticulations)
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
