import SwiftUI
import AppKit
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
    @State private var editorPage: EditorPage = .mapping

    private enum EditorPage: String, CaseIterable {
        case mapping = "Key & Velocity"
        case loop = "Waveform & Loops"
    }
    @State private var showImporter = false
    @State private var showRelinkImporter = false
    @State private var relinkOriginalPath: String?
    @State private var relinkOriginalManagedName: String?
    @State private var relinkMessage: String?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var saveNotice: String?
    @State private var showLibrary = false
    @State private var showFactory = false
    @State private var showPackageImporter = false
    @State private var showSFZImporter = false
    @State private var showSFZSampleFolderImporter = false
    @State private var pendingSFZURL: URL?
    @State private var showSF2Importer = false
    @State private var showSF2Picker = false
    @State private var sf2Source: URL?
    @State private var sf2Presets: [StudioSamplerSF2Reader.Preset] = []
    @State private var selectedSF2PresetIndex = 0
    @State private var showEXSImporter = false
    @State private var showEXSSampleFolderImporter = false
    @State private var pendingEXSURL: URL?
    @State private var showGIGImporter = false
    @State private var showGIGPicker = false
    @State private var gigSource: URL?
    @State private var gigInstruments: [StudioSamplerGIGReader.Instrument] = []
    @State private var selectedGIGIndex = 0
    @State private var compatibilityWarnings: [String] = []
    @State private var showSaveSheet = false
    @State private var exportInsteadOfSave = false
    @State private var instrumentName = "New Instrument"
    @State private var instrumentCategory = "Other"
    @State private var instrumentTags = ""

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
                Menu {
                    Button("Browse Instrument Library…") { showLibrary = true }
                    Button("Import .studioinstrument…") { showPackageImporter = true }
                    Button("Import SFZ Instrument…") { showSFZImporter = true }
                    Button("Import SoundFont 2 (.sf2)…") { showSF2Importer = true }
                    Button("Import GigaStudio (.gig)…") { showGIGImporter = true }
                    Button("Import Logic EXS24 (.exs)…") { showEXSImporter = true }
                    Divider()
                    Button("Save to Studio Library…") { beginSaving(export: false) }
                        .disabled(draft?.isValid != true)
                    Button("Export Portable Instrument…") { beginSaving(export: true) }
                        .disabled(draft?.isValid != true)
                } label: {
                    Label("Instruments", systemImage: "square.stack.3d.up")
                }
                .disabled(isImporting)
                Button {
                    showFactory = true
                } label: {
                    Label("Instrument Factory…", systemImage: "waveform.badge.mic")
                }
                .disabled(isImporting)
                Button {
                    showImporter = true
                } label: {
                    Label("Add Samples…", systemImage: "plus")
                }
                .disabled(isImporting)
                .buttonStyle(.borderedProminent)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let patch = draft, !patch.zones.isEmpty {
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
                    VStack(alignment: .leading, spacing: 8) {
                        if !FileManager.default.fileExists(atPath: zone.sampleURL.path) {
                            HStack(spacing: 10) {
                                Label("Recording missing: \(zone.sampleURL.lastPathComponent)",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Relink Sample…") { beginRelink(zone) }
                                    .disabled(isImporting)
                            }
                            .font(.caption)
                            .padding(9)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        if let relinkMessage {
                            Text(relinkMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Picker("Zone editor", selection: $editorPage) {
                            ForEach(EditorPage.allCases, id: \.self) { page in
                                Text(page.rawValue).tag(page)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                        if editorPage == .mapping {
                            zoneEditor(zone)
                        } else {
                            StudioSamplerLoopEditorView(zone: Binding(
                                get: { selectedZone ?? zone },
                                set: { edited in
                                    guard var patch = draft,
                                          patch.zones.indices.contains(selectedIndex) else { return }
                                    patch.zones[selectedIndex] = edited
                                    draft = patch
                                }
                            ))
                            .id(selectedIndex)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 42)).foregroundColor(.secondary)
                    Text("Studio Sampler is ready").font(.headline)
                    Text("Start with an empty instrument, then add WAV, AIFF, or other supported recordings. Studio will map them across the keyboard.")
                        .font(.callout).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Record / Build Instrument…") { showFactory = true }
                            .buttonStyle(.borderedProminent)
                        Button("Add Samples…") { showImporter = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            if !compatibilityWarnings.isEmpty {
                DisclosureGroup("Instrument compatibility notes (\(compatibilityWarnings.count))") {
                    ForEach(compatibilityWarnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let saveNotice {
                Label(saveNotice, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
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
            isPresented: $showRelinkImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { relinkSample(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
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
        .fileImporter(
            isPresented: $showPackageImporter,
            allowedContentTypes: [UTType(exportedAs: "com.garritanstudio.instrument", conformingTo: .package), .folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { loadPackage(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showSFZSampleFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first, let source = pendingSFZURL {
                    pendingSFZURL = nil
                    importSFZ(source, samplesRoot: folder)
                }
            case .failure(let error):
                pendingSFZURL = nil
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showSFZImporter,
            allowedContentTypes: [UTType(filenameExtension: "sfz") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importSFZ(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showSF2Importer,
            allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { inspectSF2(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showEXSSampleFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first, let source = pendingEXSURL {
                    pendingEXSURL = nil
                    importEXS(source, samplesRoot: folder)
                }
            case .failure(let error):
                pendingEXSURL = nil
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showEXSImporter,
            allowedContentTypes: [UTType(filenameExtension: "exs") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importEXS(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showGIGImporter,
            allowedContentTypes: [UTType(filenameExtension: "gig") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { inspectGIG(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showGIGPicker) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import GigaStudio Instrument").font(.title3.weight(.semibold))
                Text("Select one instrument to convert into Studio's native sampler.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Instrument", selection: $selectedGIGIndex) {
                    ForEach(gigInstruments.indices, id: \.self) { index in
                        let item = gigInstruments[index]
                        Text("\(item.name) · Bank \(item.bank), Program \(item.program) · \(item.regions.count) regions")
                            .tag(index)
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Supports 16-bit PCM, velocity splits, round-robin, release samples, explicit GIG keyswitch notes and stepped CC1/CC2 sample selection. Other controller and complex GIG dimensions remain unsupported.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") {
                        showGIGPicker = false
                        gigSource = nil
                    }
                    Spacer()
                    Button("Import Selected Instrument") {
                        guard let source = gigSource else { return }
                        showGIGPicker = false
                        gigSource = nil
                        importGIG(source, instrumentIndex: selectedGIGIndex)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!gigInstruments.indices.contains(selectedGIGIndex))
                }
            }
            .padding(20)
            .frame(width: 520)
        }
        .sheet(isPresented: $showSF2Picker) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import SoundFont Preset").font(.title3.weight(.semibold))
                Text("Choose one SoundFont preset to convert into a native, editable Studio instrument.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Preset", selection: $selectedSF2PresetIndex) {
                    ForEach(sf2Presets.indices, id: \.self) { index in
                        let preset = sf2Presets[index]
                        Text("\(preset.name) · Bank \(preset.bank), Program \(preset.program)")
                            .tag(index)
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Samples will be copied into Studio's library. Unsupported SoundFont modulation and effects will be reported.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") {
                        showSF2Picker = false
                        sf2Source = nil
                    }
                    Spacer()
                    Button("Import Selected Preset") {
                        guard let source = sf2Source else { return }
                        showSF2Picker = false
                        sf2Source = nil
                        importSF2(source, presetIndex: selectedSF2PresetIndex)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!sf2Presets.indices.contains(selectedSF2PresetIndex))
                }
            }
            .padding(20)
            .frame(width: 500)
        }
        .sheet(isPresented: $showLibrary) {
            StudioSamplerLibraryBrowser(onChoose: { url in loadPackage(url) })
        }
        .sheet(isPresented: $showFactory) {
            StudioSamplerFactoryView(viewModel: viewModel, trackID: trackID,
                                     onAdd: { takes in addFactoryTakes(takes) })
        }
        .sheet(isPresented: $showSaveSheet) {
            instrumentSaveSheet
        }
    }

    private var instrumentSaveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(exportInsteadOfSave ? "Export Portable Instrument" : "Save Studio Instrument")
                .font(.title3.weight(.semibold))
            Text("The instrument package will contain the mapping, performance settings and independent copies of all recordings.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Instrument name", text: $instrumentName)
                .textFieldStyle(.roundedBorder)
            TextField("Category (e.g. Strings, Brass, Percussion)", text: $instrumentCategory)
                .textFieldStyle(.roundedBorder)
            TextField("Tags (comma-separated)", text: $instrumentTags)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showSaveSheet = false }
                Spacer()
                Button(exportInsteadOfSave ? "Choose Export Location…" : "Save to Library") {
                    guard let patch = draft else { return }
                    let metadata = currentMetadata
                    guard metadata.isValid, patch.isValid else { return }
                    showSaveSheet = false
                    if exportInsteadOfSave {
                        DispatchQueue.main.async { exportPackage(patch, metadata: metadata) }
                    } else {
                        saveToLibrary(patch, metadata: metadata)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!currentMetadata.isValid || draft?.isValid != true)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    private var currentMetadata: StudioSamplerInstrumentPackage.Metadata {
        StudioSamplerInstrumentPackage.Metadata(
            name: instrumentName, category: instrumentCategory,
            tags: instrumentTags.split(separator: ",").map(String.init)
        )
    }

    private func beginSaving(export: Bool) {
        exportInsteadOfSave = export
        if instrumentName == "New Instrument" {
            instrumentName = viewModel.project.track(withID: trackID)?.name ?? "New Instrument"
        }
        showSaveSheet = true
    }

    private func saveToLibrary(_ patch: StudioSamplerPatch,
                               metadata: StudioSamplerInstrumentPackage.Metadata) {
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try StudioSamplerInstrumentPackage.saveToLibrary(patch, metadata: metadata)
                }.value
                saveNotice = "Saved \(metadata.name) to Studio's instrument library."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportPackage(_ patch: StudioSamplerPatch,
                               metadata: StudioSamplerInstrumentPackage.Metadata) {
        let panel = NSSavePanel()
        panel.title = "Export Studio Instrument"
        panel.prompt = "Export"
        panel.nameFieldStringValue = metadata.name + ".studioinstrument"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let chosen = panel.url else { return }
            let destination = chosen.pathExtension.lowercased() ==
                StudioSamplerInstrumentPackage.fileExtension
                ? chosen : chosen.appendingPathExtension(
                    StudioSamplerInstrumentPackage.fileExtension)
            Task { @MainActor in
                isImporting = true
                errorMessage = nil
                defer { isImporting = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try StudioSamplerInstrumentPackage.export(
                            patch, metadata: metadata, to: destination)
                    }.value
                    saveNotice = "Exported \(metadata.name) as a portable instrument."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importEXS(_ url: URL, samplesRoot: URL? = nil) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        compatibilityWarnings = []
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    let folderAccess = samplesRoot?.startAccessingSecurityScopedResource() ?? false
                    defer {
                        if folderAccess { samplesRoot?.stopAccessingSecurityScopedResource() }
                        if access { url.stopAccessingSecurityScopedResource() }
                    }
                    return try StudioSamplerEXSImporter.importInstrument(
                        url, samplesRoot: samplesRoot)
                }.value
                draft = imported.patch
                selectedIndex = 0
                instrumentName = imported.instrumentName
                compatibilityWarnings = imported.warnings
                saveNotice = "Imported EXS24 instrument \(imported.instrumentName). Choose Apply Mapping to activate it."
            } catch StudioSamplerEXSImporter.ImportError.missingAudio {
                // An EXS file may reference samples stored separately by
                // Logic. Only request folder access after the initial import
                // cannot resolve its local files.
                if samplesRoot == nil {
                    pendingEXSURL = url
                    showEXSSampleFolderImporter = true
                } else {
                    errorMessage = "A required EXS24 sample wasn't found in the selected folder. Choose a folder that contains the original sample recordings."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func inspectGIG(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let catalog = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try StudioSamplerGIGReader.inspect(url)
                }.value
                guard !catalog.instruments.isEmpty else {
                    errorMessage = "The selected GigaStudio file contains no instruments."
                    return
                }
                gigSource = url
                gigInstruments = catalog.instruments
                selectedGIGIndex = 0
                showGIGPicker = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importGIG(_ url: URL, instrumentIndex: Int) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        compatibilityWarnings = []
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try StudioSamplerGIGImporter.importInstrument(
                        url, instrumentIndex: instrumentIndex)
                }.value
                draft = imported.patch
                selectedIndex = 0
                instrumentName = imported.instrument.name
                compatibilityWarnings = imported.warnings
                saveNotice = "Imported GigaStudio instrument \(imported.instrument.name). Choose Apply Mapping to activate it."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func inspectSF2(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let catalog = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try StudioSamplerSF2Reader.inspect(url)
                }.value
                guard !catalog.presets.isEmpty else {
                    errorMessage = "The selected SoundFont contains no presets."
                    return
                }
                sf2Source = url
                sf2Presets = catalog.presets
                selectedSF2PresetIndex = 0
                showSF2Picker = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importSF2(_ url: URL, presetIndex: Int) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        compatibilityWarnings = []
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try StudioSamplerSF2Importer.importInstrument(
                        url, presetIndex: presetIndex)
                }.value
                draft = imported.patch
                selectedIndex = 0
                instrumentName = imported.preset.name
                compatibilityWarnings = imported.warnings
                saveNotice = "Imported SoundFont preset \(imported.preset.name). Choose Apply Mapping to activate it."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importSFZ(_ url: URL, samplesRoot: URL? = nil) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        compatibilityWarnings = []
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    let folderAccess = samplesRoot?.startAccessingSecurityScopedResource() ?? false
                    defer {
                        if folderAccess { samplesRoot?.stopAccessingSecurityScopedResource() }
                        if access { url.stopAccessingSecurityScopedResource() }
                    }
                    return try StudioSamplerSFZImporter.importInstrument(
                        url, samplesRoot: samplesRoot)
                }.value
                // Keep changes staged: the active instrument changes only after Apply Mapping.
                draft = imported.patch
                selectedIndex = 0
                compatibilityWarnings = imported.warnings
                saveNotice = "SFZ instrument imported into the mapping draft. Choose Apply Mapping to activate it."
            } catch StudioSamplerSFZImporter.ImportError.missingSample {
                if samplesRoot == nil {
                    pendingSFZURL = url
                    showSFZSampleFolderImporter = true
                } else {
                    errorMessage = "The SFZ instrument still has missing recordings. Choose the folder containing its original samples."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadPackage(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let (patch, metadata) = try await Task.detached(priority: .userInitiated) {
                    try StudioSamplerInstrumentPackage.load(url)
                }.value
                try viewModel.loadStudioSampler(for: trackID, patch: patch)
                restoreSaved()
                saveNotice = "Loaded \(metadata.name) from its instrument package."
            } catch {
                errorMessage = error.localizedDescription
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
            HStack {
                Text("Zone articulation")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Zone articulation", selection: Binding(
                    get: { selectedZone?.articulationID ?? 0 },
                    set: { id in
                        guard var patch = draft,
                              patch.zones.indices.contains(selectedIndex) else { return }
                        patch.zones[selectedIndex].articulationID = id
                        draft = patch
                    }
                )) {
                    Text("Default / Sustain").tag(UInt8(0))
                    ForEach(draft?.articulations ?? []) { articulation in
                        Text(articulation.name).tag(articulation.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                Button("Add Articulation") { addArticulation() }
                    .disabled((draft?.articulations?.count ?? 0) >= 15)
            }
            HStack(spacing: 22) {
                Toggle("Release sample", isOn: Binding(
                    get: { selectedZone?.isReleaseTrigger == true },
                    set: { isRelease in
                        guard var patch = draft,
                              patch.zones.indices.contains(selectedIndex) else { return }
                        patch.zones[selectedIndex].isReleaseTrigger = isRelease
                        if isRelease {
                            // Release samples are one-shots, never sustain loops.
                            patch.zones[selectedIndex].legatoFromNote = nil
                            patch.zones[selectedIndex].loopStartFrame = nil
                            patch.zones[selectedIndex].loopEndFrame = nil
                            patch.zones[selectedIndex].loopCrossfadeFrames = nil
                        }
                        draft = patch
                    }
                ))
                .toggleStyle(.switch)
                Stepper(
                    "Round-robin take: \(Int(zone.roundRobinIndex ?? 0) + 1)",
                    value: Binding(
                        get: { Int(selectedZone?.roundRobinIndex ?? 0) + 1 },
                        set: { take in
                            guard var patch = draft,
                                  patch.zones.indices.contains(selectedIndex) else { return }
                            patch.zones[selectedIndex].roundRobinIndex =
                                UInt8(clamping: max(0, take - 1))
                            draft = patch
                        }
                    ), in: 1...8
                )
                .frame(minWidth: 190)
                Spacer()
            }
            Text("Round-robin takes share one articulation, root, microphone and velocity band. Release recordings play only on note-off.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Picker("Recorded microphone", selection: Binding(
                    get: { selectedZone?.microphoneID ?? 0 },
                    set: { micID in
                        guard var patch = draft,
                              patch.zones.indices.contains(selectedIndex) else { return }
                        patch.zones[selectedIndex].microphoneID =
                            micID == 0 ? nil : micID
                        if !((patch.microphones ?? []).contains(where: { $0.id == micID })) {
                            let names = ["Close", "Main / Tree", "Room", "Spot"]
                            patch.microphones = (patch.microphones ?? []) + [
                                StudioSamplerMicrophone(id: micID, name: names[Int(micID)])
                            ]
                        }
                        draft = patch
                    }
                )) {
                    Text("Close / Default").tag(UInt8(0))
                    Text("Main / Tree").tag(UInt8(1))
                    Text("Room").tag(UInt8(2))
                    Text("Spot").tag(UInt8(3))
                }
                .frame(maxWidth: 270)
                Toggle("Recorded legato transition", isOn: Binding(
                    get: { selectedZone?.legatoFromNote != nil },
                    set: { enabled in
                        guard var patch = draft,
                              patch.zones.indices.contains(selectedIndex) else { return }
                        var zone = patch.zones[selectedIndex]
                        if enabled {
                            zone.isReleaseTrigger = nil
                            zone.loopStartFrame = nil
                            zone.loopEndFrame = nil
                            zone.loopCrossfadeFrames = nil
                            zone.legatoFromNote = zone.rootNote == 60 ? 59 : 60
                            zone.lowestNote = zone.rootNote
                            zone.highestNote = zone.rootNote
                            patch.legatoEnabled = true
                            if patch.legatoCrossfadeMilliseconds == nil {
                                patch.legatoCrossfadeMilliseconds = 40
                            }
                        } else {
                            zone.legatoFromNote = nil
                        }
                        patch.zones[selectedIndex] = zone
                        draft = patch
                    }
                )).toggleStyle(.switch)
                if zone.legatoFromNote != nil {
                    Stepper(
                        "From \(SamplerNoteNames.name(zone.legatoFromNote ?? 60)) → \(SamplerNoteNames.name(zone.rootNote))",
                        value: Binding(
                            get: { Int(selectedZone?.legatoFromNote ?? 60) },
                            set: { from in
                                guard var patch = draft,
                                      patch.zones.indices.contains(selectedIndex) else { return }
                                patch.zones[selectedIndex].legatoFromNote = UInt8(clamping: from)
                                draft = patch
                            }
                        ), in: 0...127
                    )
                }
            }
            .font(.caption)
            Text("A transition sample is triggered only if its From note overlaps the exact destination root pitch. Regular sustain recordings are still required.")
                .font(.caption2).foregroundStyle(.secondary)
            articulationEditor
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var articulationEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let items = draft?.articulations, !items.isEmpty {
                Divider()
                Text("Keyswitch map (note-on changes the articulation for future notes)")
                    .font(.caption.weight(.semibold))
                Stepper(
                    "Default / Sustain keyswitch: \(SamplerNoteNames.name(draft?.defaultKeyswitchNote ?? 23))",
                    value: Binding(
                        get: { Int(draft?.defaultKeyswitchNote ?? 23) },
                        set: { value in
                            guard var patch = draft else { return }
                            patch.defaultKeyswitchNote = UInt8(clamping: value)
                            draft = patch
                        }
                    ),
                    in: 0...127
                )
                .font(.caption)
                ForEach(items) { articulation in
                    HStack(spacing: 8) {
                        TextField("Articulation", text: Binding(
                            get: { draft?.articulations?.first(where: { $0.id == articulation.id })?.name ?? "" },
                            set: { name in updateArticulation(articulation.id, name: name) }
                        ))
                        .frame(maxWidth: 150)
                        Stepper(
                            "Keyswitch: \(SamplerNoteNames.name(articulation.keyswitchNote))",
                            value: Binding(
                                get: { Int(draft?.articulations?.first(where: { $0.id == articulation.id })?.keyswitchNote ?? 24) },
                                set: { updateArticulation(articulation.id, note: UInt8(clamping: $0)) }
                            ),
                            in: 0...127
                        )
                        .frame(maxWidth: 220)
                        Button(role: .destructive) {
                            removeArticulation(articulation.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if draft?.isValid != true {
                    Text("Please fix duplicate keyswitches, empty names, or invalid zone assignments before applying.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text("Keyswitch notes take priority over sampled notes on the same MIDI channel.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func addArticulation() {
        guard var patch = draft else { return }
        let used = Set((patch.articulations ?? []).map(\.id))
        guard let id = (1...15).map(UInt8.init).first(where: { !used.contains($0) }) else {
            return
        }
        let usedKeys = Set((patch.articulations ?? []).map(\.keyswitchNote))
        guard let note = (24...127).map(UInt8.init).first(where: { !usedKeys.contains($0) }) else {
            return
        }
        let names = ["Legato", "Staccato", "Pizzicato", "Spiccato",
                     "Tremolo", "Harmonics", "Marcato", "Short", "Long"]
        let index = patch.articulations?.count ?? 0
        let name = index < names.count ? names[index] : "Articulation \(Int(id))"
        patch.articulations = (patch.articulations ?? []) +
            [StudioSamplerArticulation(id: id, name: name, keyswitchNote: note)]
        if patch.defaultKeyswitchNote == nil { patch.defaultKeyswitchNote = 23 }
        draft = patch
    }

    private func updateArticulation(_ id: UInt8, name: String? = nil,
                                    note: UInt8? = nil) {
        guard var patch = draft,
              let index = patch.articulations?.firstIndex(where: { $0.id == id })
        else { return }
        if let name { patch.articulations?[index].name = name }
        if let note { patch.articulations?[index].keyswitchNote = note }
        draft = patch
    }

    private func removeArticulation(_ id: UInt8) {
        guard var patch = draft else { return }
        patch.articulations?.removeAll(where: { $0.id == id })
        if patch.articulations?.isEmpty == true { patch.defaultKeyswitchNote = nil }
        for index in patch.zones.indices where patch.zones[index].articulationID == id {
            patch.zones[index].articulationID = nil
        }
        if patch.selectedArticulationID == id { patch.selectedArticulationID = nil }
        draft = patch
    }

    private func restoreSaved() {
        relinkMessage = nil
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
            patch.envelope = draft.envelope
            patch.articulations = draft.articulations ?? patch.articulations
            patch.defaultKeyswitchNote = draft.defaultKeyswitchNote ?? patch.defaultKeyswitchNote
            patch.selectedArticulationID = draft.selectedArticulationID
            patch.microphones = draft.microphones ?? patch.microphones
            patch.legatoEnabled = draft.legatoEnabled ?? patch.legatoEnabled
            patch.legatoCrossfadeMilliseconds =
                draft.legatoCrossfadeMilliseconds ?? patch.legatoCrossfadeMilliseconds
            patch.vibratoCC21 = draft.vibratoCC21
            patch.breathCC2 = draft.breathCC2
            // Preserve distinct edits when the same imported recording
            // appears in multiple articulations or velocity zones. Consume
            // each matching old zone only once during automatic remapping.
            var unmatched = draft.zones
            for index in patch.zones.indices {
                if let previous = unmatched.firstIndex(where: {
                    $0.filePath == patch.zones[index].filePath
                }) {
                    let oldZone = unmatched.remove(at: previous)
                    patch.zones[index].loopStartFrame = oldZone.loopStartFrame
                    patch.zones[index].loopEndFrame = oldZone.loopEndFrame
                    patch.zones[index].loopCrossfadeFrames = oldZone.loopCrossfadeFrames
                    patch.zones[index].trimStartFrame = oldZone.trimStartFrame
                    patch.zones[index].trimEndFrame = oldZone.trimEndFrame
                    patch.zones[index].fadeInFrames = oldZone.fadeInFrames
                    patch.zones[index].fadeOutFrames = oldZone.fadeOutFrames
                    patch.zones[index].articulationID = oldZone.articulationID
                    patch.zones[index].roundRobinIndex =
                        oldZone.roundRobinIndex ?? patch.zones[index].roundRobinIndex
                    patch.zones[index].isReleaseTrigger =
                        oldZone.isReleaseTrigger ?? patch.zones[index].isReleaseTrigger
                    patch.zones[index].microphoneID =
                        oldZone.microphoneID ?? patch.zones[index].microphoneID
                    patch.zones[index].legatoFromNote =
                        oldZone.legatoFromNote ?? patch.zones[index].legatoFromNote
                }
            }
            self.draft = patch
            selectedIndex = 0
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginRelink(_ zone: StudioSamplerZone) {
        relinkOriginalPath = zone.filePath
        relinkOriginalManagedName = zone.managedFileName
        showRelinkImporter = true
    }

    private func relinkSample(_ url: URL) {
        guard let originalPath = relinkOriginalPath else { return }
        let originalManagedName = relinkOriginalManagedName
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            defer {
                isImporting = false
                relinkOriginalPath = nil
                relinkOriginalManagedName = nil
            }
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try StudioSamplerSampleLibrary.importFiles([url])
                }.value
                guard let newFile = files.first, var patch = draft else { return }
                let managedName = StudioSamplerSampleLibrary.managedName(for: newFile)
                var repaired = 0
                for index in patch.zones.indices {
                    if patch.zones[index].filePath == originalPath ||
                       (originalManagedName != nil &&
                        patch.zones[index].managedFileName == originalManagedName) {
                        patch.zones[index].filePath = newFile.path
                        patch.zones[index].managedFileName = managedName
                        repaired += 1
                    }
                }
                if repaired > 0 {
                    draft = patch
                    relinkMessage = "Relinked \(repaired) zone(s) in the draft. Apply Mapping to activate."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The capture modal hands temporary prepared WAVs to this task. On a
    /// failed mapping import, Studio backs up those recordings inside the
    /// user's application support folder instead of losing the performance.
    private func addFactoryTakes(_ takes: [StudioSamplerFactoryTake]) {
        guard !takes.isEmpty else { return }
        guard !isImporting else {
            Task { @MainActor in
                do {
                    let backup = try await Task.detached(priority: .utility) {
                        try StudioSamplerFactoryRecovery.preserve(takes)
                    }.value
                    errorMessage = "Another sampler import was in progress. Your prepared recordings are safe at \(backup.path)."
                } catch {
                    errorMessage = "Another sampler import was in progress. The temporary recordings were retained; recovery failed: \(error.localizedDescription)"
                }
            }
            return
        }
        let original = draft
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let rebuilt = try await Task.detached(priority: .userInitiated) {
                    do {
                        let result = try StudioSamplerInstrumentFactory.assemble(
                            takes, extending: original)
                        for take in takes {
                            try? FileManager.default.removeItem(at: take.source)
                        }
                        return result
                    } catch {
                        let underlying = error.localizedDescription
                        if let backup = try? StudioSamplerFactoryRecovery.preserve(takes) {
                            for take in takes {
                                try? FileManager.default.removeItem(at: take.source)
                            }
                            throw NSError(domain: "StudioSamplerFactory",
                                          code: 1, userInfo: [
                                NSLocalizedDescriptionKey:
                                    "\(underlying) Prepared recordings were saved for recovery at \(backup.path)"
                            ])
                        }
                        throw NSError(domain: "StudioSamplerFactory", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey:
                            "\(underlying) Recovery backup failed; prepared recordings remain in the temporary folder."])
                    }
                }.value
                selectedIndex = original?.zones.count ?? 0
                draft = rebuilt
                saveNotice = "Added \(takes.count) original recording(s) to the instrument draft. Review the map and choose Apply Mapping."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importSamples(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        let original = draft
        isImporting = true
        errorMessage = nil
        saveNotice = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let rebuilt = try await Task.detached(priority: .userInitiated) {
                    try StudioSamplerSampleLibrary.importMappedFiles(
                        urls, extending: original)
                }.value
                selectedIndex = original?.zones.count ?? 0
                draft = rebuilt
                saveNotice = "Imported \(urls.count) recording(s). Review the new mapping, then choose Apply Mapping."
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
