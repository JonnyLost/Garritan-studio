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

// MARK: - V-Rack Sidebar View

/// Sidebar panel for managing V-Rack instruments
public struct VRackView: View {
    @ObservedObject var viewModel: ProjectViewModel
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
    @State private var showNativeARIAWarning = false


    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(ComposerDrawerMode.allCases) { option in
                    Button {
                        mode = option
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
                    upcomingPanel(title: "Channel", symbol: "slider.horizontal.3", detail: "Selected-track controls will appear here.")
                case .stage:
                    upcomingPanel(title: "Stage", symbol: "circle.grid.cross", detail: "Drag instruments to position them on the stage.")
                case .articulations:
                    upcomingPanel(title: "Articulations", symbol: "music.quarternote.3", detail: "Playing techniques and expressions for the selected track.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Open Original ARIA Player?", isPresented: $showNativeARIAWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Open Anyway") {
                if let id = selectedARIAID {
                    viewModel.openTrackInstrumentUI(id, preferNativeARIA: true)
                }
            }
        } message: {
            Text("ARIA's original editor has crashed Studio on this Mac. Save your project before trying it. Generic Plugin Controls are safer.")
        }
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
        catalog.filter { instrument in
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

    private func chooseInstrument(_ instrument: DrawerInstrument) {
        guard !isLoadingInstrument else { return }
        guard let trackID = viewModel.selectedTrackID,
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

    private var instrumentsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Instrument Picker").font(.headline)
                    Text("Choose a sound for the selected track")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                if let trackID = selectedARIAID {
                    Menu {
                        Button("Open Plugin Controls") {
                            viewModel.openTrackInstrumentUI(trackID)
                        }
                        Button("Open Original ARIA Player…") {
                            showNativeARIAWarning = true
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
                                        Image(systemName: instrument.symbol)
                                            .font(.system(size: 18))
                                            .frame(width: 30, height: 34)
                                            .foregroundColor(.accentColor)
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
