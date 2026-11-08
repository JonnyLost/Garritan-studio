import SwiftUI
import DAWCore
import AVFoundation

// MARK: - Multifunction Composer Drawer

private enum ComposerDrawerMode: String, CaseIterable, Identifiable {
    case instruments = "Instruments"
    case channel = "Channel"
    case stage = "Stage"
    case articulations = "Articulations"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .instruments: return "music.note.list"
        case .channel: return "slider.horizontal.3"
        case .stage: return "circle.grid.cross"
        case .articulations: return "music.quarternote.3"
        }
    }
}


@MainActor
private final class BrowserAudition: ObservableObject {
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var errorMessage: String?
    private var engine: AVAudioEngine?
    private var unit: AVAudioUnitMIDIInstrument?
    private var task: Task<Void, Never>?
    private var token = UUID()

    func stop() {
        token = UUID()
        task?.cancel()
        task = nil
        for note: UInt8 in [60, 64, 67, 72] { unit?.stopNote(note, onChannel: 0) }
        engine?.stop()
        engine = nil
        unit = nil
        isLoading = false
        isPlaying = false
    }

    func play(library: String, path: String, viewModel: ProjectViewModel) {
        stop()
        errorMessage = nil
        isLoading = true
        let request = token
        task = Task { @MainActor in
            do {
                if !viewModel.pluginHost.availableInstruments.contains(where: {
                    $0.identifier.name.localizedCaseInsensitiveContains("aria") &&
                    $0.identifier.manufacturer.localizedCaseInsensitiveContains("garr")
                }) {
                    await viewModel.pluginHost.scanForPlugins()
                }
                guard request == token else { return }
                guard let description = viewModel.pluginHost.availableInstruments.first(where: {
                    $0.identifier.name.localizedCaseInsensitiveContains("aria") &&
                    $0.identifier.manufacturer.localizedCaseInsensitiveContains("garr")
                }) else {
                    throw NSError(domain: "BrowserAudition", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Garritan ARIA Player was not found."])
                }
                let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
                let loaded = try await viewModel.pluginHost.loadPlugin(identifier: description.identifier, format: format)
                guard request == token else { return }
                guard let instrument = loaded.audioUnit as? AVAudioUnitMIDIInstrument else {
                    throw NSError(domain: "BrowserAudition", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "ARIA MIDI audition is unavailable."])
                }
                let previewEngine = AVAudioEngine()
                let converterMixer = AVAudioMixerNode()
                previewEngine.attach(instrument)
                previewEngine.attach(converterMixer)
                // ARIA can expose a native render format different from the
                // requested host format. Match the working track routing:
                // AU native output -> converter mixer -> engine main mixer.
                let nativeFormat = instrument.outputFormat(forBus: 0)
                print("[BrowserAudition] ARIA output format: \(nativeFormat)")
                print("[BrowserAudition] Host format: \(format)")
                previewEngine.connect(instrument, to: converterMixer, format: nativeFormat)
                previewEngine.connect(converterMixer, to: previewEngine.mainMixerNode, format: format)
                converterMixer.outputVolume = 1.0
                print("[BrowserAudition] AU connections: \(previewEngine.outputConnectionPoints(for: instrument, outputBus: 0).count)")
                print("[BrowserAudition] Mixer connections: \(previewEngine.outputConnectionPoints(for: converterMixer, outputBus: 0).count)")
                try TrackGarritanLoader.apply(TrackGarritanProgram(library: library, programName: path), to: instrument)
                print("[BrowserAudition] Program loaded: \(path)")
                try previewEngine.start()
                print("[BrowserAudition] Engine started: \(previewEngine.isRunning)")
                guard request == token else { previewEngine.stop(); return }
                engine = previewEngine
                unit = instrument
                // GPO instruments often use CC1 for dynamic volume; a fresh
                // ARIA instance may be silent until modulation/expression is set.
                instrument.sendController(7, withValue: 110, onChannel: 0)
                instrument.sendController(11, withValue: 127, onChannel: 0)
                instrument.sendController(1, withValue: 100, onChannel: 0)
                print("[BrowserAudition] Initialized MIDI CC7=110 CC11=127 CC1=100")
                // Give ARIA time to finish loading sample data before sounding notes.
                print("[BrowserAudition] Waiting 2 seconds for sample readiness")
                try await Task.sleep(for: .seconds(2))
                guard request == token && !Task.isCancelled else { return }
                print("[BrowserAudition] Sample readiness wait completed")
                isLoading = false
                isPlaying = true
                for note: UInt8 in [60, 64, 67, 72] {
                    guard request == token && !Task.isCancelled else { break }
                    print("[BrowserAudition] Note on: \(note)")
                    instrument.startNote(note, withVelocity: 88, onChannel: 0)
                    try? await Task.sleep(for: .milliseconds(900))
                    instrument.stopNote(note, onChannel: 0)
                    print("[BrowserAudition] Note off: \(note)")
                    try? await Task.sleep(for: .milliseconds(90))
                }
                if request == token { stop() }
            } catch {
                if request == token {
                    print("[BrowserAudition] ERROR: \(error)")
                    stop()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - V-Rack Sidebar View

/// Sidebar panel for managing V-Rack instruments
public struct VRackView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    var openStageWorkspace: (() -> Void)?
    var openInstrumentWorkspace: (() -> Void)?
    var closeInstrumentWorkspace: (() -> Void)?
    var expandedOnly: Bool = false
    @State private var showPluginBrowser = false
    @State private var selectedRackInstrumentID: UUID?
    @State private var mode: ComposerDrawerMode = .instruments
    @State private var searchText = ""
    @State private var libraryFilter = "All Libraries"
    @State private var familyFilter = "All"
    @State private var instrumentSet = "Core Orchestra"
    @State private var catalog: [DrawerInstrument] = []
    @State private var isLoadingInstrument = false
    @State private var pickerError: String?
    @StateObject private var audition = BrowserAudition()
    @State private var previewInstrumentID: String?
    @State private var instrumentTypeFilter = "All"


    public init(viewModel: ProjectViewModel, openStageWorkspace: (() -> Void)? = nil,
                openInstrumentWorkspace: (() -> Void)? = nil,
                closeInstrumentWorkspace: (() -> Void)? = nil,
                expandedOnly: Bool = false) {
        self.viewModel = viewModel
        self.openStageWorkspace = openStageWorkspace
        self.openInstrumentWorkspace = openInstrumentWorkspace
        self.closeInstrumentWorkspace = closeInstrumentWorkspace
        self.expandedOnly = expandedOnly
    }

    public var body: some View {
        Group {
            if expandedOnly {
                expandedInstrumentBrowser
            } else {
                compactDrawer
            }
        }
    }

    private var compactDrawer: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(ComposerDrawerMode.allCases) { option in
                    Button {
                        mode = option
                        if option == .stage { openStageWorkspace?() }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: option.symbol)
                                .font(.system(size: 17))
                            Text(option.rawValue)
                                .font(.system(size: 9))
                        }
                        .foregroundColor(mode == option ? .white : .secondary)
                        .frame(width: 68, height: 58)
                        .background(mode == option ? Color.accentColor : Color.clear)
                        .cornerRadius(9)
                    }
                    .buttonStyle(.plain)
                    .help(option.rawValue)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.top, 8)
            .frame(width: 78)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch mode {
                case .instruments:
                    instrumentsPanel
                case .channel:
                    channelInspector
                case .stage:
                    stagePanel
                case .articulations:
                    upcomingPanel(title: "Articulations", symbol: "music.quarternote.3", detail: "Playing techniques and expressions for the selected track.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showPluginBrowser) {
            if let rackID = selectedRackInstrumentID {
                RackPluginBrowserSheet(
                    viewModel: viewModel,
                    rackInstrumentID: rackID,
                    isPresented: $showPluginBrowser
                )
            }
        }
    }

    // MARK: - Orchestral Stage v1
    // Stage interaction lives in its own small SwiftUI view to keep the
    // compiler's result-builder expressions manageable.
    private var stagePanel: some View {
        OrchestralStageView(viewModel: viewModel)
    }

    private func upcomingPanel(title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct DrawerInstrument: Identifiable {
        let library: String
        let path: String
        var id: String { library + ":" + path }
        var name: String { String(path.split(separator: "/").last ?? Substring(path)) }
        var family: String {
            let parts = path.split(separator: "/").map(String.init)
            let index = parts.first == "Standard" ? 1 : 0
            return parts.count > index + 1 ? parts[index] : "Other"
        }
        var category: String {
            let f = family.lowercased()
            if f.contains("woodwind") || f.contains("flute") || f.contains("clarinet") { return "Woodwinds" }
            if f.contains("brass") { return "Brass" }
            if f.contains("percussion") || f.contains("drum") { return "Percussion" }
            if f.contains("string") || f.contains("violin") { return "Strings" }
            if f.contains("keyboard") || f.contains("piano") { return "Keys" }
            if f.contains("choir") || f.contains("vocal") { return "Choir" }
            if f.contains("synth") || f.contains("electronic") { return "Synth" }
            if f.contains("world") || f.contains("ethnic") { return "World" }
            return "Other"
        }
        var instrumentType: String {
            let components = path.split(separator: "/").map(String.init)
            let familyIndex = components.first == "Standard" ? 1 : 0
            if components.count > familyIndex + 2 {
                return components[familyIndex + 1]
            }
            return family
        }
        var symbol: String {
            switch category {
            case "Woodwinds": return "wind"
            case "Brass": return "music.note"
            case "Percussion": return "circle.dotted"
            case "Strings": return "music.note.list"
            case "Keys": return "pianokeys"
            case "Choir": return "person.3"
            case "Synth": return "waveform"
            default: return "music.note"
            }
        }
    }

    private let scoreFamilies = ["Woodwinds", "Brass", "Percussion", "Keys", "Choir", "Strings", "Synth", "World", "Other"]

    /// Hide only numbered individual players in orchestral families.
    private func isIndividualPlayer(_ instrument: DrawerInstrument) -> Bool {
        guard instrument.library == "Garritan Personal Orchestra 5",
              ["Woodwinds", "Brass", "Strings", "Choir"].contains(instrument.category) else {
            return false
        }
        return instrument.name.range(
            of: #"(?:^|[\s_-])(?:Plr|Player)\s*\d+\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private var filteredCatalog: [DrawerInstrument] {
        (catalog.isEmpty ? (Self.cachedCatalog ?? []) : catalog).filter { instrument in
            (libraryFilter == "All Libraries" || instrument.library == libraryFilter) &&
            (familyFilter == "All" || instrument.category == familyFilter) &&
            (instrumentSet == "Complete" || !isIndividualPlayer(instrument)) &&
            (searchText.isEmpty || instrument.name.localizedCaseInsensitiveContains(searchText) ||
             instrument.path.localizedCaseInsensitiveContains(searchText))
        }.sorted { lhs, rhs in
            let li = scoreFamilies.firstIndex(of: lhs.category) ?? 99
            let ri = scoreFamilies.firstIndex(of: rhs.category) ?? 99
            if li != ri { return li < ri }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func displayInstrumentType(_ type: String) -> String {
        // Garritan bank folder names use ordering prefixes, e.g. "03 Clarinets".
        // Keep the underlying folder name intact for accurate catalog filtering.
        type.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
    }

    private var availableInstrumentTypes: [String] {
        Array(Set(filteredCatalog.map(\.instrumentType))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var expandedFilteredCatalog: [DrawerInstrument] {
        filteredCatalog.filter {
            instrumentTypeFilter == "All" || $0.instrumentType == instrumentTypeFilter
        }
    }

    @MainActor private static var cachedCatalog: [DrawerInstrument]?

    private func discoverCatalog() {
        if let cached = Self.cachedCatalog {
            catalog = cached
            return
        }
        let banks: [(String, String, String?)] = [
            ("Garritan Personal Orchestra 5",
             "/Library/Application Support/Garritan/Garritan Personal Orchestra 5/Banks/Standard/Personal Orchestra 5.bank.xml", "Standard/"),
            ("Garritan Instant Orchestra",
             "/Library/Application Support/Garritan/Garritan Instant Orchestra/Banks/Standard/Instant Orchestra.bank.xml", nil)
        ]
        let loaded = banks.flatMap { library, path, prefix in
            GPO5BankReader.loadStandardPrograms(bankPath: path, requiredPrefix: prefix).map {
                DrawerInstrument(library: library, path: $0.name)
            }
        }
        Self.cachedCatalog = loaded
        catalog = loaded
    }

    private func chooseInstrument(_ instrument: DrawerInstrument, targetTrackID: TrackID? = nil) {
        guard !isLoadingInstrument else { return }
        guard let trackID = targetTrackID ?? viewModel.selectedTrackID,
              let track = viewModel.project.track(withID: trackID),
              track.type == .midi || track.type == .instrument else {
            pickerError = "Select a MIDI or instrument track first."
            return
        }
        pickerError = nil
        isLoadingInstrument = true
        Task { @MainActor in
            defer { isLoadingInstrument = false }
            do {
                let program = TrackGarritanProgram(library: instrument.library, programName: instrument.path)
                let unit: AVAudioUnit
                if let existing = viewModel.playbackEngine.instrument(for: trackID),
                   case .auInstrument(let loadedUnit, _) = existing,
                   let pluginID = track.instrumentSlot?.pluginID,
                   pluginID.name.localizedCaseInsensitiveContains("aria"),
                   pluginID.manufacturer.localizedCaseInsensitiveContains("garr") {
                    unit = loadedUnit
                } else {
                    // Discover ARIA using the same host used by the original instrument browser.
                    if !viewModel.pluginHost.availableInstruments.contains(where: {
                        $0.identifier.name.localizedCaseInsensitiveContains("aria") &&
                        $0.identifier.manufacturer.localizedCaseInsensitiveContains("garr")
                    }) {
                        await viewModel.pluginHost.scanForPlugins()
                    }
                    guard let description = viewModel.pluginHost.availableInstruments.first(where: {
                        $0.identifier.name.localizedCaseInsensitiveContains("aria") &&
                        $0.identifier.manufacturer.localizedCaseInsensitiveContains("garr")
                    }) else {
                        throw NSError(domain: "GarritanPicker", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Garritan ARIA Player was not found."])
                    }
                    let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
                    let loaded = try await viewModel.pluginHost.loadPlugin(
                        identifier: description.identifier, format: format)
                    try await viewModel.playbackEngine.loadInstrument(
                        loaded.audioUnit, for: trackID, pluginID: loaded.id)
                    if var updated = viewModel.project.track(withID: trackID) {
                        updated.instrumentSlot = PluginSlot(pluginID: description.identifier, isEnabled: true)
                        viewModel.updateTrack(updated, description: "Load ARIA Instrument")
                    }
                    unit = loaded.audioUnit
                }
                try TrackGarritanLoader.apply(program, to: unit)
                // ARIA program loading can reset its internal fader.
                viewModel.restoreInstrumentLevel(for: trackID)
                // Store the catalog choice and the actual ARIA state on the track.
                if var updated = viewModel.project.track(withID: trackID) {
                    let oldName = updated.name
                    let oldProgram = updated.garritanProgramID
                    let previousDefaultName = oldProgram.flatMap { id in
                        catalog.first(where: { $0.id == id })?.name
                    }
                    let isDefaultName = oldName.range(
                        of: #"^(?:Midi|Instrument) \d+$"#, options: [.regularExpression, .caseInsensitive]
                    ) != nil
                    if isDefaultName || (previousDefaultName != nil && oldName == previousDefaultName) {
                        updated.name = instrument.name
                    }
                    updated.garritanProgramID = instrument.id
                    updated.instrumentSlot?.stateData = try PropertyListSerialization.data(
                        fromPropertyList: unit.auAudioUnit.fullState ?? [:],
                        format: .binary, options: 0)
                    viewModel.updateTrack(updated, description: "Assign Garritan Instrument")
                }
                pickerError = nil
                print("[Instrument Picker] Loaded \\(instrument.name) on track \\(trackID)")
            } catch {
                pickerError = error.localizedDescription
                print("[Instrument Picker] Load failed: \\(error)")
            }
        }
    }

    private func addInstrumentTrack(_ instrument: DrawerInstrument) {
        guard !isLoadingInstrument else { return }
        print("[Instrument Picker] Add as New Track: beginning track creation for \(instrument.name)")
        viewModel.addTrack(type: .instrument, name: instrument.name)
        print("[Instrument Picker] Add as New Track: track creation returned")
        guard let newTrackID = viewModel.selectedTrackID else {
            pickerError = "Could not create the instrument track."
            return
        }
        print("[Instrument Picker] Add as New Track: beginning ARIA load for \(newTrackID)")
        chooseInstrument(instrument, targetTrackID: newTrackID)
    }

    // Studio-level controls: intentionally independent of ARIA's own mixer.
    private var channelInspector: some View {
        Group {
            if let id = viewModel.selectedTrackID,
               let track = viewModel.project.track(withID: id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CHANNEL")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(track.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text(track.garritanProgramID?.components(separatedBy: ":").last?.components(separatedBy: "/").last ?? "No instrument loaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Track Volume")
                                Spacer()
                                Text(String(format: "%.0f%%", track.volume * 100))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(viewModel.project.track(withID: id)?.volume ?? 1) },
                                set: { viewModel.setTrackVolume(id: id, volume: Float($0)) }
                            ), in: 0...1)
                        }
                        ChannelStereoMeter(engine: viewModel.audioEngine, trackID: id)
                        if track.instrumentSlot != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Instrument Level (CC7)")
                                    Spacer()
                                    Text(track.instrumentLevelCC7.map { "\($0) / 127" } ?? "Not set")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { Double(viewModel.project.track(withID: id)?.instrumentLevelCC7 ?? 100) },
                                    set: { viewModel.setInstrumentLevel(id: id, value: UInt8(min(127, max(0, Int($0.rounded()))))) }
                                ), in: 0...127, step: 1)
                                HStack {
                                    Text("ARIA MIDI Channel")
                                    Spacer()
                                    Picker("ARIA MIDI Channel", selection: Binding<Int>(
                                        get: { Int(viewModel.project.track(withID: id)?.instrumentLevelChannel ?? 0) },
                                        set: { viewModel.setInstrumentLevelChannel(id: id, channel: UInt8($0)) }
                                    )) {
                                        ForEach(0..<16, id: \.self) { channel in
                                            Text("\(channel + 1)").tag(channel)
                                        }
                                    }
                                    .labelsHidden()
                                }
                                .font(.caption)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MIDI Output")
                                .font(.subheadline)
                            Picker("MIDI Output", selection: Binding<Int>(
                                get: { viewModel.project.track(withID: id)?.midiOutputChannel.map { Int($0) } ?? -1 },
                                set: { viewModel.setTrackMIDIOutputChannel(id: id, channel: $0 < 0 ? nil : UInt8($0)) }
                            )) {
                                Text("All Channels").tag(-1)
                                ForEach(0..<16, id: \.self) { channel in
                                    Text("Channel \(channel + 1)").tag(channel)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            Text("All preserves each event's MIDI channel.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Pan")
                                Spacer()
                                Text(track.pan == 0 ? "Center" : String(format: "%.0f%% %@", abs(track.pan) * 100, track.pan < 0 ? "L" : "R"))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(viewModel.project.track(withID: id)?.pan ?? 0) },
                                set: { viewModel.setTrackPan(id: id, pan: Float($0)) }
                            ), in: -1...1)
                            HStack {
                                Text("L")
                                Spacer()
                                Text("C")
                                Spacer()
                                Text("R")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Button("Center Pan") { viewModel.setTrackPan(id: id, pan: 0) }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                        HStack(spacing: 12) {
                            Toggle("Mute", isOn: Binding(
                                get: { viewModel.project.track(withID: id)?.isMuted ?? false },
                                set: { newValue in
                                    if (viewModel.project.track(withID: id)?.isMuted ?? false) != newValue {
                                        viewModel.toggleTrackMute(id: id)
                                    }
                                }
                            ))
                            Toggle("Solo", isOn: Binding(
                                get: { viewModel.project.track(withID: id)?.isSolo ?? false },
                                set: { newValue in
                                    if (viewModel.project.track(withID: id)?.isSolo ?? false) != newValue {
                                        viewModel.toggleTrackSolo(id: id)
                                    }
                                }
                            ))
                        }
                        .toggleStyle(.checkbox)
                        Divider()
                        if selectedARIAID == id {
                            Button {
                                viewModel.openTrackInstrumentUI(id, preferNativeARIA: true)
                            } label: {
                                Label("Open ARIA Player", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("Choose an instrument in the Instruments tab to enable plugin controls.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Room and stage positioning will be project-level controls, independent of the instrument library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No Track Selected", systemImage: "slider.horizontal.3", description: Text("Select a track to inspect its channel."))
            }
        }
    }

    private var selectedARIAID: TrackID? {
        guard let id = viewModel.selectedTrackID,
              let track = viewModel.project.track(withID: id),
              let plugin = track.instrumentSlot?.pluginID,
              plugin.name.localizedCaseInsensitiveContains("aria"),
              plugin.manufacturer.localizedCaseInsensitiveContains("garr"),
              let loaded = viewModel.playbackEngine.instrument(for: id),
              case .auInstrument = loaded else { return nil }
        return id
    }

    // Full-width browser shares the same catalog, filters and ARIA loader
    // as the compact picker. Browsing never loads a patch until requested.
    private var previewInstrument: DrawerInstrument? {
        (catalog.isEmpty ? (Self.cachedCatalog ?? []) : catalog).first { $0.id == previewInstrumentID }
    }

    var expandedInstrumentBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Instrument Browser")
                        .font(.system(size: 23, weight: .semibold,
                                      design: palette.appearance == .gpo5Modern ? .default : .serif))
                    Text("Explore Garritan libraries and choose a patch for the selected track")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(filteredCatalog.count) patches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { closeInstrumentWorkspace?() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panel)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search instruments or articulations", text: $searchText)
                    .textFieldStyle(.plain)
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(palette.secondaryText)
                Menu {
                    Button("All Libraries") { libraryFilter = "All Libraries" }
                    Button("Garritan Personal Orchestra 5") {
                        libraryFilter = "Garritan Personal Orchestra 5"
                    }
                    Button("Garritan Instant Orchestra") {
                        libraryFilter = "Garritan Instant Orchestra"
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(libraryFilter == "All Libraries" ? "All Libraries" :
                             libraryFilter == "Garritan Personal Orchestra 5" ? "GPO5" : "Instant Orchestra")
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 9)
                    .frame(width: 126, height: 27)
                    .background(palette.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(palette.separator, lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Library filter")
                Text("SET")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(palette.secondaryText)
                Menu {
                    Button("Core Orchestra") { instrumentSet = "Core Orchestra" }
                    Button("Complete") { instrumentSet = "Complete" }
                } label: {
                    HStack(spacing: 6) {
                        Text(instrumentSet == "Core Orchestra" ? "Core" : "Complete")
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 9)
                    .frame(width: 85, height: 27)
                    .background(palette.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(palette.separator, lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Instrument set filter")
            }
            .padding(12)
            .background(palette.surface)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(["All"] + scoreFamilies, id: \.self) { family in
                            Button {
                                familyFilter = family
                                instrumentTypeFilter = "All"
                                audition.stop()
                                previewInstrumentID = nil
                            } label: {
                                HStack {
                                    Text(family == "All" ? "All Instruments" : family)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(familyFilter == family ? palette.selectedBackground : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 165)
                .background(palette.sidebar)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(["All"] + availableInstrumentTypes, id: \.self) { type in
                            Button {
                                instrumentTypeFilter = type
                                audition.stop()
                                previewInstrumentID = nil
                            } label: {
                                HStack {
                                    Text(type == "All" ? "All Types" : displayInstrumentType(type))
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(instrumentTypeFilter == type ?
                                            palette.selectedBackground : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 155)
                .background(palette.panel)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(expandedFilteredCatalog) { instrument in
                            Button {
                                audition.stop()
                                previewInstrumentID = instrument.id
                            } label: {
                                HStack(spacing: 12) {
                                    StudioInstrumentIcon(
                                        name: instrument.name,
                                        path: instrument.path,
                                        category: instrument.category,
                                        size: 31
                                    )
                                    .frame(width: 35)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(instrument.name)
                                            .font(.subheadline.weight(.medium))
                                        Text(instrument.category + " · " +
                                             (instrument.library == "Garritan Personal Orchestra 5" ? "GPO5" : "Instant Orchestra"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if previewInstrumentID == instrument.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                                .padding(10)
                                .background(previewInstrumentID == instrument.id ?
                                            palette.selectedBackground :
                                            palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                        if expandedFilteredCatalog.isEmpty {
                            Text("No instruments match these filters.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity)
                .background(palette.canvas)
                Divider()
                // Keep loading actions visible at every editor height.
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("INSTRUMENT DETAILS")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.1)
                                .foregroundStyle(palette.secondaryText)

                            if let instrument = previewInstrument {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(palette.surface)
                                    StudioInstrumentIcon(
                                        name: instrument.name,
                                        path: instrument.path,
                                        category: instrument.category,
                                        size: 88
                                    )
                                    .padding(.vertical, 10)
                                }
                                .frame(height: 114)

                                Text(instrument.name)
                                    .font(.system(size: 20, weight: .semibold,
                                                  design: palette.appearance == .gpo5Modern ? .default : .serif))
                                    .foregroundStyle(palette.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 6) {
                                    Circle().fill(palette.accent).frame(width: 7, height: 7)
                                    Text(instrument.category.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.8)
                                        .foregroundStyle(palette.secondaryText)
                                }
                                Divider()

                                Text("LIBRARY")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(1.0)
                                    .foregroundStyle(palette.secondaryText)
                                Text(instrument.library)
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text("PATCH LOCATION")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(1.0)
                                    .foregroundStyle(palette.secondaryText)
                                Text(instrument.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            } else {
                                Text("Choose an instrument to see its details and load it.")
                                    .font(.subheadline)
                                    .foregroundStyle(palette.secondaryText)
                            }

                            if isLoadingInstrument { ProgressView("Loading instrument…") }
                            if let pickerError {
                                Text(pickerError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    VStack(spacing: 9) {
                        if let instrument = previewInstrument {
                            Button {
                                audition.stop()
                                chooseInstrument(instrument)
                            } label: {
                                Label("Load on Selected Track", systemImage: "arrow.down.to.line")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoadingInstrument || viewModel.selectedTrackID == nil)

                            Button {
                                audition.stop()
                                addInstrumentTrack(instrument)
                            } label: {
                                Label("Add as New Track", systemImage: "plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLoadingInstrument)
                        } else {
                            Text("Select a patch to begin")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .controlSize(.regular)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(palette.surface)
                }
                .frame(width: 273)
                .frame(maxHeight: .infinity)
                .background(palette.panel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .tint(palette.accent)
        .onAppear {
            if catalog.isEmpty { discoverCatalog() }
            if previewInstrumentID == nil {
                previewInstrumentID = filteredCatalog.first?.id
            }
        }
        .onDisappear { audition.stop() }
        .onChange(of: familyFilter) { _, _ in
            if !filteredCatalog.contains(where: { $0.id == previewInstrumentID }) {
                previewInstrumentID = filteredCatalog.first?.id
            }
        }
        .onChange(of: catalog.count) { _, _ in
            if previewInstrumentID == nil {
                previewInstrumentID = filteredCatalog.first?.id
            }
        }
    }

    private var instrumentsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Instrument Picker").font(.headline)
                    Text("Choose a sound for the selected track")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    openInstrumentWorkspace?()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help("Open the full instrument browser")
                if let trackID = selectedARIAID {
                    Menu {
                        Button("Open Plugin Controls") {
                            viewModel.openTrackInstrumentUI(trackID)
                        }
                        Button("Open Original ARIA Player…") {
                            viewModel.openTrackInstrumentUI(trackID, preferNativeARIA: true)
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("ARIA controls for the selected track")
                }
                Button { viewModel.addRackInstrument() } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.plain)
                .help("Add shared V-Rack instrument (advanced)")
            }
            .padding(12)
            Divider()
            VStack(spacing: 6) {
                TextField("Search instruments", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 5) {
                    Picker("Library", selection: $libraryFilter) {
                        Text("All").tag("All Libraries")
                        Text("GPO5").tag("Garritan Personal Orchestra 5")
                        Text("Instant").tag("Garritan Instant Orchestra")
                    }
                    .help("Instrument library")
                    Picker("Family", selection: $familyFilter) {
                        Text("All Families").tag("All")
                        ForEach(scoreFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .help("Instrument family")
                    Picker("Instrument Set", selection: $instrumentSet) {
                        Text("Core").tag("Core Orchestra")
                        Text("Complete").tag("Complete")
                    }
                    .help("Core Orchestra hides numbered players; Complete shows all instruments")
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if isLoadingInstrument {
                ProgressView("Loading instrument…")
                    .controlSize(.small)
                    .padding(.horizontal, 10)
            }
            if let pickerError {
                Text(pickerError).font(.caption).foregroundColor(.red).padding(.horizontal, 10)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scoreFamilies, id: \.self) { family in
                        let instruments = filteredCatalog.filter { $0.category == family }
                        if !instruments.isEmpty {
                            Text(family.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 5)
                            ForEach(instruments) { instrument in
                                Button { chooseInstrument(instrument) } label: {
                                    HStack(spacing: 9) {
                                        StudioInstrumentIcon(
                                            name: instrument.name,
                                            path: instrument.path,
                                            category: instrument.category,
                                            size: 30
                                        )
                                        .frame(width: 32, height: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(instrument.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(instrument.library == "Garritan Personal Orchestra 5" ? "GPO5" : "Instant Orchestra")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(viewModel.selectedTrackID.flatMap { viewModel.project.track(withID: $0)?.garritanProgramID } == instrument.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if catalog.isEmpty {
                        Text("No Garritan banks found on this Mac.")
                            .font(.caption).foregroundColor(.secondary).padding(16)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(filteredCatalog.count) instruments")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text(viewModel.selectedTrackID == nil ? "Select a MIDI track" : "Track selected")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(9)
        }
        .onAppear { if catalog.isEmpty { discoverCatalog() } }
    }

}

// MARK: - Rack Instrument Row

struct RackInstrumentRow: View {
    let instrument: RackInstrument
    @ObservedObject var viewModel: ProjectViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onShowBrowser: () -> Void
    @State private var showNativeWarning = false
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Instrument icon/button
                Button(action: {
                    if instrument.pluginSlot.pluginID != nil {
                        viewModel.openRackInstrumentUI(instrument.id)
                    } else {
                        onShowBrowser()
                    }
                }) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 14))
                        .foregroundColor(instrument.pluginSlot.pluginID != nil ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading, spacing: 2) {
                    // Instrument name
                    Text(instrument.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    
                    // Plugin name or "Empty"
                    Text(instrument.pluginSlot.pluginID?.name ?? "Empty - Click to load")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()

                if instrument.pluginSlot.pluginID?.name.localizedCaseInsensitiveContains("aria") == true {
                    Button("Open ARIA…") { showNativeWarning = true }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .help("Open ARIA's original editor (may crash on this Mac)")
                }

                // Mute button
                Button(action: {
                    viewModel.toggleRackInstrumentMute(instrument.id)
                }) {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(instrument.isMuted ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .background(instrument.isMuted ? Color.orange.opacity(0.2) : Color.clear)
                .cornerRadius(3)
                
                // Delete button
                Button(action: {
                    viewModel.removeRackInstrument(instrument.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .alert("Open Original ARIA Player?", isPresented: $showNativeWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Open Anyway") {
                viewModel.openRackInstrumentUI(instrument.id, preferNativeARIA: true)
            }
        } message: {
            Text("The native ARIA editor has previously crashed Studio on this Mac. Save your work first. The generic instrument controls remain available through the keyboard icon.")
        }
    }
}

// MARK: - Plugin Browser Sheet for V-Rack

struct RackPluginBrowserSheet: View {
    @ObservedObject var viewModel: ProjectViewModel
    let rackInstrumentID: UUID
    @Binding var isPresented: Bool
    
    @State private var isScanning = false
    @State private var searchText = ""
    
    private var filteredPlugins: [PluginIdentifier] {
        if searchText.isEmpty {
            return viewModel.availableInstrumentPlugins
        }
        return viewModel.availableInstrumentPlugins.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.manufacturer.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Instrument")
                    .font(.headline)
                Spacer()
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button("Cancel") {
                    isPresented = false
                }
            }
            .padding()
            
            // Search field
            TextField("Search instruments...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)
            
            Divider()
            
            // Plugin list
            if isScanning {
                VStack {
                    Spacer()
                    ProgressView("Scanning for instruments...")
                    Spacer()
                }
            } else if filteredPlugins.isEmpty {
                VStack {
                    Spacer()
                    Text("No instruments found")
                        .foregroundColor(.secondary)
                    Text("Make sure you have AU instruments installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredPlugins, id: \.uniqueID) { plugin in
                            Button(action: {
                                // Log to file
                                let msg = "[VRACK] Loading plugin: \(plugin.name)\n"
                                try? msg.write(toFile: "/tmp/musio_vrack.log", atomically: true, encoding: .utf8)
                                print(msg)
                                
                                Task {
                                    do {
                                        try? "Starting loadRackInstrumentPlugin...\n".write(toFile: "/tmp/musio_vrack.log", atomically: false, encoding: .utf8)
                                        await viewModel.loadRackInstrumentPlugin(rackInstrumentID, pluginID: plugin)
                                        try? "loadRackInstrumentPlugin completed\n".write(toFile: "/tmp/musio_vrack.log", atomically: false, encoding: .utf8)
                                    }
                                }
                                isPresented = false
                            }) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(plugin.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(plugin.manufacturer)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
        .onAppear {
            // Scan for plugins if not already done
            if viewModel.pluginHost.availableInstruments.isEmpty {
                isScanning = true
                Task {
                    await viewModel.pluginHost.scanForPlugins()
                    await MainActor.run {
                        isScanning = false
                    }
                }
            }
        }
    }
}


// MARK: - Channel Meter

/// Read-only stereo peaks measured after the track's gain, pan and mute stages.
private struct ChannelStereoMeter: View {
    @ObservedObject var engine: AudioEngine
    let trackID: TrackID

    var body: some View {
        let levels = engine.trackPeakLevels[trackID] ?? [0, 0]
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Stereo Level")
                Spacer()
                Text("L / R")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(0..<2, id: \.self) { channel in
                HStack(spacing: 7) {
                    Text(channel == 0 ? "L" : "R")
                        .font(.caption2.monospaced())
                        .frame(width: 12)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(levels[channel] > 0.9 ? Color.orange : Color.green)
                                .frame(width: geometry.size.width * CGFloat(levels[channel]))
                        }
                    }
                    .frame(height: 7)
                }
            }
        }
        .accessibilityLabel("Stereo track output levels")
    }
}
