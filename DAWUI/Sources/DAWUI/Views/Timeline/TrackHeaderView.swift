import SwiftUI
import DAWCore
import AVFoundation
import Compression
import Foundation

// MARK: - Track Header View

struct TrackHeaderView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    var onCreateClip: (() -> Void)? = nil
    
    @State private var isEditing = false
    @State private var editedName = ""
    @State private var showInstrumentBrowser = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Track color indicator
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: track.color.hex) ?? .blue)
                    .frame(width: 4, height: 60)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Track name
                    if isEditing {
                        TextField("Track Name", text: $editedName, onCommit: {
                            commitNameEdit()
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(track.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                startEditing()
                            }
                    }
                    
                    // Instrument slot for MIDI/Instrument tracks
                    if track.type == .midi || track.type == .instrument {
                        HStack(spacing: 4) {
                            // MIDI Activity indicator
                            MIDIActivityIndicator(
                                isActive: viewModel.midiActivity && track.isArmed,
                                isArmed: track.isArmed
                            )
                            
                            InstrumentSlotButton(
                                track: track,
                                viewModel: viewModel,
                                showBrowser: $showInstrumentBrowser
                            )
                            
                            // MIDI Output selector (for routing to V-Rack)
                            MIDIOutputSelector(track: track, viewModel: viewModel, showBrowser: $showInstrumentBrowser)
                        }
                    } else if track.type == .audio {
                        // Audio track with input selector
                        HStack(spacing: 4) {
                            Image(systemName: trackTypeIcon)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            AudioInputSelector(track: track, viewModel: viewModel)
                        }
                    } else {
                        // Track type icon for other track types (bus, master)
                        HStack(spacing: 2) {
                            Image(systemName: trackTypeIcon)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            Text(track.type.rawValue.capitalized)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Controls
                    HStack(spacing: 4) {
                        // Record arm
                        Button(action: { toggleArmed() }) {
                            Image(systemName: track.isArmed ? "record.circle.fill" : "record.circle")
                                .font(.system(size: 11))
                                .foregroundColor(track.isArmed ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(track.isArmed ? "Disarm Track" : "Arm Track for Recording")
                        
                        // Mute
                        Button(action: { viewModel.toggleTrackMute(id: track.id) }) {
                            Text("M")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(track.isMuted ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        // Solo
                        Button(action: { viewModel.toggleTrackSolo(id: track.id) }) {
                            Text("S")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(track.isSolo ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        // Volume meter - shows input level for armed V-Rack tracks, otherwise output level
                        TrackMiniMeter(
                            level: meterLevel,
                            isInputMeter: showInputMeter
                        )
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            
            Divider()
        }
        .sheet(isPresented: $showInstrumentBrowser) {
            InstrumentBrowserSheet(
                viewModel: viewModel,
                trackID: track.id,
                isPresented: $showInstrumentBrowser
            )
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // Instant selection with piano roll follow (no animation delay)
            withAnimation(.none) {
                viewModel.selectAndArmTrack(track.id)
            }
        }
        .contextMenu {
            Button("Rename") { startEditing() }
            Button("Duplicate") { duplicateTrack() }
            
            Divider()
            
            if track.type == .midi || track.type == .instrument {
                Button("Create MIDI Clip") {
                    viewModel.createMIDIClip(on: track.id, at: TimePosition(), duration: 4.0)
                }
            } else if track.type == .audio {
                Button("Create Audio Clip...") {
                    onCreateClip?()
                }
            }
            
            Divider()
            
            Button("Delete", role: .destructive) {
                viewModel.deleteTrack(id: track.id)
            }
        }
    }
    
    private var isSelected: Bool {
        viewModel.selectedTrackID == track.id
    }
    
    private var trackTypeIcon: String {
        switch track.type {
        case .audio: return "waveform"
        case .midi: return "pianokeys"
        case .instrument: return "pianokeys.inverse"
        case .bus: return "arrow.triangle.merge"
        case .master: return "speaker.wave.3"
        }
    }
    
    /// Whether to show input meter (for armed audio tracks with V-Rack input)
    private var showInputMeter: Bool {
        track.type == .audio && track.isArmed && track.inputSource == .vRackSum
    }
    
    /// Meter level - shows V-Rack input when armed with V-Rack input, otherwise track output
    private var meterLevel: Float {
        if showInputMeter {
            // Show V-Rack input level
            return (viewModel.playbackEngine.vRackInputLevel.left + viewModel.playbackEngine.vRackInputLevel.right) / 2
        } else {
            // Show track output level
            return viewModel.playbackEngine.trackMeterLevels[track.id]?.left ?? 0
        }
    }
    
    private func startEditing() {
        editedName = track.name
        isEditing = true
    }
    
    private func commitNameEdit() {
        isEditing = false
        if !editedName.isEmpty && editedName != track.name {
            var updatedTrack = track
            updatedTrack.name = editedName
            viewModel.updateTrack(updatedTrack, description: "Rename Track")
        }
    }
    
    private func toggleArmed() {
        var updatedTrack = track
        updatedTrack.isArmed.toggle()
        viewModel.updateTrack(updatedTrack, description: updatedTrack.isArmed ? "Arm Track" : "Disarm Track")
    }
    
    private func duplicateTrack() {
        var newTrack = track
        newTrack.id = TrackID()
        newTrack.name = "\(track.name) Copy"
        viewModel.addTrack(type: track.type, name: newTrack.name)
    }
}

// MARK: - Track Mini Meter

struct TrackMiniMeter: View {
    let level: Float  // 0-1 normalized level
    var isInputMeter: Bool = false  // True for input metering (uses cyan color scheme)
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<6, id: \.self) { i in
                Rectangle()
                    .fill(meterColor(for: i))
                    .frame(width: 3, height: CGFloat(6 + i * 2))
            }
        }
    }
    
    private func meterColor(for index: Int) -> Color {
        // Check if level exceeds this segment's threshold
        let isActive = level >= (Float(index) / 6.0)
        
        if isInputMeter {
            // Input meter uses cyan/blue color scheme
            if index < 4 {
                // Cyan zone
                return isActive ? .cyan.opacity(0.9) : .cyan.opacity(0.15)
            } else if index < 5 {
                // Orange zone (getting hot)
                return isActive ? .orange.opacity(0.9) : .orange.opacity(0.15)
            } else {
                // Red zone (clipping)
                return isActive ? .red.opacity(0.9) : .red.opacity(0.15)
            }
        } else {
            // Output meter uses green color scheme
            if index < 4 {
                // Green zone
                return isActive ? .green.opacity(0.9) : .green.opacity(0.15)
            } else if index < 5 {
                // Yellow zone
                return isActive ? .yellow.opacity(0.9) : .yellow.opacity(0.15)
            } else {
                // Red zone
                return isActive ? .red.opacity(0.9) : .red.opacity(0.15)
            }
        }
    }
}

// MARK: - Track Controls View

struct TrackControlsView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 8) {
            // Volume fader
            VStack(spacing: 2) {
                Text(volumeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { Double(track.volume) },
                        set: { viewModel.setTrackVolume(id: track.id, volume: Float($0)) }
                    ),
                    in: 0...1
                )
                .frame(width: 60)
            }
            
            // Pan knob (simplified as slider)
            VStack(spacing: 2) {
                Text(panText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { Double(track.pan) },
                        set: { viewModel.setTrackPan(id: track.id, pan: Float($0)) }
                    ),
                    in: -1...1
                )
                .frame(width: 60)
            }
        }
    }
    
    private var volumeText: String {
        let db = 20 * log10(track.volume)
        if db == -.infinity { return "-∞ dB" }
        return String(format: "%.1f dB", db)
    }
    
    private var panText: String {
        if abs(track.pan) < 0.01 { return "C" }
        if track.pan < 0 { return String(format: "%.0fL", -track.pan * 100) }
        return String(format: "%.0fR", track.pan * 100)
    }
}

// MARK: - Instrument Slot Button

struct InstrumentSlotButton: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var showBrowser: Bool
    
    var body: some View {
        Button(action: {
            showBrowser = true
        }) {
            HStack(spacing: 4) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 9))
                
                if let pluginID = track.instrumentSlot?.pluginID {
                    Text(pluginID.name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                } else {
                    Text("No Instrument")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(track.instrumentSlot?.pluginID != nil ? Color.purple.opacity(0.3) : Color.gray.opacity(0.2))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if track.instrumentSlot?.pluginID != nil {
                Button("Browse / Change Instrument...") { showBrowser = true }
                Button("Open Instrument Controls...") { openInstrumentUI() }
                Divider()
                Button("Remove Instrument", role: .destructive) { removeInstrument() }
            } else {
                Button("Load Instrument...") { showBrowser = true }
            }
        }
    }
    
    private func openInstrumentUI() {
        guard let slot = track.instrumentSlot,
              let pluginID = slot.pluginID,
              let loadedPlugin = viewModel.pluginHost.loadedPlugins.values.first(where: { $0.identifier == pluginID }) else { return }
        
        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
    }
    
    private func removeInstrument() {
        var updatedTrack = track
        updatedTrack.instrumentSlot = nil
        viewModel.updateTrack(updatedTrack, description: "Remove Instrument")
        viewModel.playbackEngine.removeInstrument(for: track.id)
    }
}

// Read-only ARIA AU state inspection. Does not write to the Audio Unit.
private struct ARIARackSlot {
    let number: Int
    let patch: String
    let midiChannel: String?
}

private final class ARIARackXMLReader: NSObject, XMLParserDelegate {
    var slots: [ARIARackSlot] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        if elementName.localizedCaseInsensitiveContains("instrument") ||
           elementName.localizedCaseInsensitiveContains("slot") {
            print("[ARIA Rack] XML element: \(elementName); attributes: \(attributes)")
        }
        guard elementName == "Slot" else { return }
        let slotNumber = Int(attributes["id"] ?? "") ?? -1
        guard (0..<16).contains(slotNumber) else { return }
        let patch = attributes["name"] ?? ""
        guard !patch.isEmpty else { return }
        let channel = (attributes["channel"] ?? attributes["midiChannel"])
            .flatMap { Int($0) }
            .map { String($0 + 1) }
        slots.append(ARIARackSlot(number: slotNumber, patch: patch, midiChannel: channel))
    }
}

private enum ARIARackStateReader {
    static func inspect(_ unit: AVAudioUnit) -> [ARIARackSlot]? {
        guard let state = unit.auAudioUnit.fullState else {
            print("[ARIA Rack] AU fullState unavailable")
            return nil
        }
        print("[ARIA Rack] AU state keys: \(state.keys.sorted())")
        guard let blob = state["AriaData"] as? Data else {
            print("[ARIA Rack] No AriaData in fullState")
            return nil
        }
        print("[ARIA Rack] AriaData bytes: \(blob.count)")
        let bytes = [UInt8](blob)
        guard bytes.count > 14, Array(bytes.prefix(4)) == Array("CEGP".utf8) else { return nil }
        let expected = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 |
                           UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        guard expected > 0 && expected < 8_000_000 else { return nil }
        let compressed = Array(bytes[10..<(bytes.count - 4)])
        var plain = [UInt8](repeating: 0, count: expected)
        let decoded = compressed.withUnsafeBufferPointer { src in
            plain.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!,
                                          src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == expected else {
            print("[ARIA Rack] Decompression failed: decoded \(decoded), expected \(expected)")
            return nil
        }
        print("[ARIA Rack] Decoded XML bytes: \(decoded)")
        let reader = ARIARackXMLReader()
        let parser = XMLParser(data: Data(plain))
        parser.delegate = reader
        guard parser.parse() else {
            print("[ARIA Rack] XML parsing failed: \(parser.parserError?.localizedDescription ?? "unknown")")
            return nil
        }
        print("[ARIA Rack] Parsed occupied slots: \(reader.slots.count)")
        return reader.slots
    }
}

// MARK: - Instrument Browser Sheet

struct InstrumentBrowserSheet: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    @Binding var isPresented: Bool
    
    @State private var searchText = ""
    @FocusState private var searchHasFocus: Bool
    @State private var isLoading = false
    @State private var isScanning = false
    @State private var instruments: [PluginDescription] = []
    @State private var loadError: String?
    @State private var programs: [TrackGarritanProgram] = []
    @State private var selectedLibrary = "Garritan Personal Orchestra 5"
    @State private var selectedFamily = "All"
    @State private var selectedProgramID: String?
    @State private var workspacePage = 0
    @State private var selectedRackSlot = 0
    @State private var inspectedRackSlots: [ARIARackSlot] = []
    @State private var rackInspectionSucceeded = false
    @State private var rackLoadTarget: Int? = nil
    // Visual rack only: ARIA's individual slot state is not exposed here yet.
    // Do not infer a slot assignment from the track's AU instrument identity.

    private var trackARIA: AVAudioUnit? {
        guard let track = viewModel.project.track(withID: trackID),
              let id = track.instrumentSlot?.pluginID,
              id.name.localizedCaseInsensitiveContains("aria"),
              id.manufacturer.localizedCaseInsensitiveContains("garr"),
              let instrument = viewModel.playbackEngine.instrument(for: trackID),
              case .auInstrument(let unit, _) = instrument else { return nil }
        return unit
    }
    private var libraryPrograms: [TrackGarritanProgram] {
        programs.filter { $0.library == selectedLibrary }
    }
    private func family(of program: TrackGarritanProgram) -> String {
        let components = program.programName.split(separator: "/").map(String.init)
        let first = components.first == "Standard" ? 1 : 0
        return components.count > first + 1 ? components[first] : "Other"
    }
    private var families: [String] {
        ["All"] + Array(Set(libraryPrograms.map { family(of: $0) })).sorted()
    }
    private var matchingPrograms: [TrackGarritanProgram] {
        libraryPrograms.filter {
            (selectedFamily == "All" || family(of: $0) == selectedFamily) &&
            (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) ||
             $0.programName.localizedCaseInsensitiveContains(searchText))
        }
    }
    private var selectedProgram: TrackGarritanProgram? {
        matchingPrograms.first { $0.id == selectedProgramID }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "pianokeys")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Garritan Instrument Workspace")
                        .font(.title3.weight(.semibold))
                    Text("Browse libraries, explore families, and load a patch into your track.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(viewModel.project.track(withID: trackID)?.name ?? "MIDI Track")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Button("Done") { isPresented = false }
            }
            .padding(16)

            if let error = loadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error).font(.caption).foregroundColor(.red)
                    Spacer()
                    Button("Dismiss") { loadError = nil }
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 16)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    workspacePage = 0
                } label: {
                    Label("Instrument Browser", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .tint(workspacePage == 0 ? Color.accentColor : Color.secondary)
                Button {
                    workspacePage = 1
                    refreshRackInspection()
                } label: {
                    Label("ARIA Rack", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .tint(workspacePage == 1 ? Color.accentColor : Color.secondary)
                Spacer()
                if workspacePage == 1 {
                    Text("Experimental slot loading")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            Divider()
            if workspacePage == 0 {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search instruments and categories…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchHasFocus)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.055))
            .cornerRadius(8)
            .padding(.horizontal, 16)

            }
            if workspacePage == 1 {
                ariaRackPreview
            } else if trackARIA != nil && !isLoading {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LIBRARIES").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                        ForEach(["Garritan Personal Orchestra 5", "Garritan Instant Orchestra"], id: \.self) { library in
                            Button {
                                selectedLibrary = library
                                selectedFamily = "All"
                                selectedProgramID = nil
                            } label: {
                                HStack {
                                    Image(systemName: "books.vertical")
                                    Text(library == "Garritan Personal Orchestra 5" ? "Personal Orchestra 5" : "Instant Orchestra")
                                    Spacer()
                                }
                                .padding(8)
                                .background(selectedLibrary == library ? Color.accentColor.opacity(0.18) : Color.clear)
                                .cornerRadius(7)
                            }.buttonStyle(.plain)
                        }
                        Divider()
                        Text("FAMILIES").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(families, id: \.self) { family in
                                    Button {
                                        selectedFamily = family
                                        selectedProgramID = nil
                                    } label: {
                                        HStack {
                                            Text(family).lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(selectedFamily == family ? Color.accentColor.opacity(0.18) : Color.clear)
                                        .cornerRadius(6)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(width: 220)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.primary.opacity(0.035))
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(selectedFamily == "All" ? "All Instruments" : selectedFamily)
                                .font(.headline)
                            Spacer()
                            Text("\(matchingPrograms.count) patches")
                                .font(.caption).foregroundColor(.secondary)
                        }.padding(.horizontal, 12).padding(.top, 12)
                        List(matchingPrograms, id: \.id, selection: $selectedProgramID) { program in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(program.name).font(.system(size: 13, weight: .medium))
                                Text(program.programName).font(.caption2)
                                    .foregroundColor(.secondary).lineLimit(1)
                            }
                            .tag(program.id)
                        }
                        .listStyle(.inset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("INSTRUMENT DETAILS")
                            .font(.caption2.weight(.bold)).foregroundColor(.secondary)
                        if let program = selectedProgram {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40)).foregroundColor(.accentColor)
                            Text(program.name).font(.title3.weight(.semibold))
                            Text(program.library).font(.caption).foregroundColor(.secondary)
                            Divider()
                            Text("Bank path").font(.caption.weight(.medium))
                            Text(program.programName)
                                .font(.caption).foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                applyProgram(program)
                            } label: {
                                Label(rackLoadTarget.map { "Load into Slot \($0 + 1) (Experimental)" } ?? "Load Instrument", systemImage: "arrow.down.to.line")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Spacer()
                            Image(systemName: "music.note")
                                .font(.largeTitle).foregroundColor(.secondary)
                            Text("Select a patch to see its details")
                                .font(.callout).foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                    .padding(16)
                    .frame(width: 235)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            } else if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading instrument...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isScanning {
                VStack {
                    ProgressView()
                    Text("Scanning for plugins...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instruments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No instruments found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Make sure you have Audio Unit instruments installed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Scan for Plugins") {
                        scanForPlugins()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredInstruments) { plugin in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(plugin.identifier.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(plugin.identifier.manufacturer)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let clickMsg = "TAP: \(plugin.identifier.name)\n"
                                try? clickMsg.write(toFile: "/tmp/musio_click.log", atomically: true, encoding: .utf8)
                                loadInstrument(plugin)
                            }
                            
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 920, height: 610)
        .onAppear {
            if trackARIA != nil { discoverPrograms() }
            else { scanForPlugins() }
            // Give the sheet time to become key before assigning text focus.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.keyWindow?.makeKey()
                searchHasFocus = true
            }
        }
    }
    
    private var ariaRackPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ARIA Instrument Rack").font(.title3.weight(.semibold))
                    Text("Read-only view of ARIA's instrument-slot state.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Refresh Slots", systemImage: "arrow.clockwise") {
                    refreshRackInspection()
                }
                .buttonStyle(.bordered)
                Label(trackARIA == nil ? "ARIA not loaded" : "ARIA connected",
                      systemImage: trackARIA == nil ? "circle.dashed" : "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(trackARIA == nil ? .secondary : .green)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(0..<16, id: \.self) { index in
                    Button {
                        selectedRackSlot = index
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(String(format: "%02d", index + 1))
                                    .font(.caption.monospacedDigit().weight(.bold))
                                Spacer()
                                Image(systemName: "pianokeys")
                                    .foregroundColor(.secondary)
                            }
                            Text(inspectedRackSlots.first(where: { $0.number == index })?.patch.components(separatedBy: "/").last
                                 ?? (rackInspectionSucceeded ? "No patch reported" : "Not inspected"))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(inspectedRackSlots.first(where: { $0.number == index })?.midiChannel
                                 .map { "MIDI channel \($0)" } ?? "Channel not verified")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(selectedRackSlot == index
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.primary.opacity(0.045))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(selectedRackSlot == index
                                              ? Color.accentColor : Color.secondary.opacity(0.15),
                                              lineWidth: selectedRackSlot == index ? 2 : 1)
                        }
                        .cornerRadius(9)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slot \(selectedRackSlot + 1)")
                        .font(.headline)
                    Text(inspectedRackSlots.first(where: { $0.number == selectedRackSlot })?.patch
                         ?? (rackInspectionSucceeded
                             ? "No instrument assignment reported for this slot."
                             : "Could not decode ARIA slot state."))
                        .font(.caption)
                        .textSelection(.enabled)
                    Text("Experimental slot loading; MIDI routing controls are not enabled.")
                        .font(.caption2).foregroundColor(.secondary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Load into Slot \(selectedRackSlot + 1)…") {
                    rackLoadTarget = selectedRackSlot
                    workspacePage = 0
                }
                .buttonStyle(.borderedProminent)
                .disabled(!rackInspectionSucceeded ||
                          inspectedRackSlots.contains(where: { $0.number == selectedRackSlot }))
                Button("Browse Instruments") {
                    rackLoadTarget = nil
                    workspacePage = 0
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func refreshRackInspection() {
        if let unit = trackARIA, let slots = ARIARackStateReader.inspect(unit) {
            inspectedRackSlots = slots
            rackInspectionSucceeded = true
            print("[ARIA Rack] Refresh succeeded, slots: \(slots.count)")
        } else {
            inspectedRackSlots = []
            rackInspectionSucceeded = false
            print("[ARIA Rack] Refresh failed: ARIA unavailable or state unreadable")
        }
    }

    private func discoverPrograms() {
        let banks: [(String, String, String?)] = [
            ("Garritan Personal Orchestra 5",
             "/Library/Application Support/Garritan/Garritan Personal Orchestra 5/Banks/Standard/Personal Orchestra 5.bank.xml", "Standard/"),
            ("Garritan Instant Orchestra",
             "/Library/Application Support/Garritan/Garritan Instant Orchestra/Banks/Standard/Instant Orchestra.bank.xml", nil)
        ]
        programs = banks.flatMap { library, path, prefix in
            GPO5BankReader.loadStandardPrograms(bankPath: path, requiredPrefix: prefix).map {
                TrackGarritanProgram(library: library, programName: $0.name)
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func applyProgram(_ program: TrackGarritanProgram) {
        guard let unit = trackARIA else {
            loadError = "No ARIA instrument on this track."
            return
        }
        do {
            if let target = rackLoadTarget {
                try ARIARackSlotLoader.load(program, slot: target, unit: unit)
                rackLoadTarget = nil
                workspacePage = 1
                refreshRackInspection()
            } else {
                try TrackGarritanLoader.apply(program, to: unit)
                isPresented = false
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func scanForPlugins() {
        isScanning = true
        Task {
            await viewModel.pluginHost.scanForPlugins()
            await MainActor.run {
                instruments = viewModel.pluginHost.availableInstruments
                isScanning = false
                print("[InstrumentBrowser] Found \(instruments.count) instruments")
            }
        }
    }
    
    private var filteredInstruments: [PluginDescription] {
        instruments.filter { plugin in
            searchText.isEmpty || plugin.identifier.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private func log(_ message: String) {
        let logPath = "/tmp/musio_instrument_load.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let fullMessage = "[\(timestamp)] \(message)\n"
        if let data = fullMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
        print(message)  // Also print for good measure
    }
    
    private func loadInstrument(_ description: PluginDescription) {
        isLoading = true
        loadError = nil
        
        // Clear log file
        try? "".write(toFile: "/tmp/musio_instrument_load.log", atomically: true, encoding: .utf8)
        
        log("========================================")
        log("Starting to load: \(description.identifier.name)")
        log("Manufacturer: \(description.identifier.manufacturer)")
        log("Track ID: \(trackID)")
        
        Task {
            do {
                log("Step 1: Creating audio format...")
                let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
                log("Format: \(format)")
                
                log("Step 2: Loading plugin from host...")
                let loadedPlugin = try await viewModel.pluginHost.loadPlugin(
                    identifier: description.identifier,
                    format: format
                )
                log("Step 2 DONE: Plugin loaded: \(loadedPlugin.name)")
                
                // Update track's instrument slot
                if var track = viewModel.project.track(withID: trackID) {
                    log("Step 3: Updating track slot...")
                    track.instrumentSlot = PluginSlot(pluginID: description.identifier, isEnabled: true)
                    
                    await MainActor.run {
                        viewModel.updateTrack(track, description: "Load Instrument")
                    }
                    log("Step 3 DONE: Track updated")
                    
                    // Load instrument into playback engine
                    log("Step 4: Loading into playback engine...")
                    try await viewModel.playbackEngine.loadInstrument(
                        loadedPlugin.audioUnit,
                        for: trackID,
                        pluginID: loadedPlugin.id
                    )
                    log("Step 4 DONE: Playback engine loaded")
                    
                    await MainActor.run {
                        // Do not automatically create the Audio Unit editor.
                        // ARIA Player can crash inside its custom editor on macOS
                        // even after the audio unit itself has loaded successfully.
                        // The instrument slot remains clickable to open the editor
                        // manually after we verify that audio/MIDI hosting works.
                        log("Step 5: Skipping automatic plugin editor (diagnostic mode)")
                        isPresented = false
                        log("Step 5 DONE: Instrument loaded; browser closed without opening editor")
                    }
                } else {
                    log("ERROR: Track not found for ID: \(trackID)")
                }
            } catch {
                log("❌ ERROR loading instrument: \(error)")
                log("Error type: \(type(of: error))")
                log("Error description: \(error.localizedDescription)")
                await MainActor.run { 
                    isLoading = false 
                    loadError = error.localizedDescription
                }
            }
            log("========================================")
        }
    }
}

// MARK: - MIDI Activity Indicator

struct MIDIActivityIndicator: View {
    let isActive: Bool
    let isArmed: Bool
    
    var body: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: isActive ? .green : .clear, radius: 3)
            .animation(.easeOut(duration: 0.05), value: isActive)
            .help(isArmed ? "MIDI Activity (track armed)" : "Arm track to receive MIDI")
    }
    
    private var indicatorColor: Color {
        if isActive {
            return .green
        } else if isArmed {
            return .green.opacity(0.3)
        } else {
            return .gray.opacity(0.3)
        }
    }
}

// MARK: - MIDI Output Selector

/// Compact selector for MIDI output destination (track instrument or V-Rack)
struct MIDIOutputSelector: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var showBrowser: Bool

    private var ariaUnit: AVAudioUnit? {
        guard let id = track.instrumentSlot?.pluginID,
              id.name.localizedCaseInsensitiveContains("aria"),
              id.manufacturer.localizedCaseInsensitiveContains("garr"),
              let instrument = viewModel.playbackEngine.instrument(for: track.id),
              case .auInstrument(let unit, _) = instrument else { return nil }
        return unit
    }

    private var currentDestinationLabel: String {
        switch track.midiOutput {
        case .rackInstrument(let id, let channel):
            if let instrument = viewModel.project.vRack.instrument(withID: id) {
                return "\(instrument.name) Ch\(channel)"
            }
            return "Instrument Ch\(channel)"
        case .trackInstrument, .none:
            return "Track"
        }
    }
    
    var body: some View {
        Menu {
            // Direct patch selection is temporarily disabled: the cascading menu
            // corrupts ARIA playback, while the separate instrument picker works.
            Button("Browse / Change Track Instrument...") { showBrowser = true }
            Divider()
            // Track instrument option
            Button(action: {
                setMIDIOutput(.trackInstrument)
            }) {
                HStack {
                    Text("Track Instrument")
                    if case .trackInstrument = track.midiOutput {
                        Image(systemName: "checkmark")
                    } else if track.midiOutput == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            // V-Rack instruments
            if viewModel.project.vRack.instruments.isEmpty {
                Text("No Instruments Loaded")
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.project.vRack.instruments) { instrument in
                    Menu(instrument.name) {
                        ForEach(1...16, id: \.self) { channel in
                            Button("Channel \(channel)") {
                                setMIDIOutput(.rackInstrument(id: instrument.id, channel: UInt8(channel)))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 8))
                Text(currentDestinationLabel)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private func setMIDIOutput(_ destination: MIDIOutputDestination) {
        var updatedTrack = track
        updatedTrack.midiOutput = destination
        viewModel.updateTrack(updatedTrack, description: "Set MIDI Output")
    }
}

// MARK: - Audio Input Selector

/// Compact selector for audio input source (hardware input or V-Rack sum)
struct AudioInputSelector: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    
    private var currentInputLabel: String {
        guard let inputSource = track.inputSource else {
            return "None"
        }
        return inputSource.displayName
    }
    
    var body: some View {
        Menu {
            // None option
            Button(action: {
                setInputSource(.none)
            }) {
                HStack {
                    Text("None")
                    if track.inputSource == nil || track.inputSource == .none {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            // V-Rack Sum option
            Button(action: {
                setInputSource(.vRackSum)
            }) {
                HStack {
                    Text("V-Rack Sum")
                    if track.inputSource == .vRackSum {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            // Hardware input options
            Text("Hardware Inputs")
                .foregroundColor(.secondary)
            
            ForEach(0..<8, id: \.self) { channel in
                Button(action: {
                    setInputSource(.audioDevice(channelIndex: channel))
                }) {
                    HStack {
                        Text("Input \(channel + 1)")
                        if case .audioDevice(let idx) = track.inputSource, idx == channel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: inputSourceIcon)
                    .font(.system(size: 9))
                Text(currentInputLabel)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(inputSourceBackground)
            .cornerRadius(3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private var inputSourceIcon: String {
        switch track.inputSource {
        case .vRackSum:
            return "square.stack.3d.up.fill"
        case .audioDevice:
            return "mic.fill"
        default:
            return "waveform"
        }
    }
    
    private var inputSourceBackground: Color {
        switch track.inputSource {
        case .vRackSum:
            return Color.purple.opacity(0.3)
        case .audioDevice:
            return Color.green.opacity(0.3)
        default:
            return Color.secondary.opacity(0.1)
        }
    }
    
    private func setInputSource(_ source: InputSource) {
        var updatedTrack = track
        updatedTrack.inputSource = source
        viewModel.updateTrack(updatedTrack, description: "Set Audio Input")
    }
}

private struct TrackGarritanProgram {
    let library: String
    let programName: String
    var id: String { library + ":" + programName }
    var name: String { String(programName.split(separator: "/").last ?? Substring(programName)) }
}

private enum TrackGarritanLoader {
    static func apply(_ program: TrackGarritanProgram, to unit: AVAudioUnit) throws {
        let instant = program.library == "Garritan Instant Orchestra"
        let sourceName = instant ? "Blending Textures/Evolving Orchestra" :
        "Standard/05 Keyboards/Concert Pianos/Intimate D"
        let fileName = instant ? "Evolving Orchestra.aupreset" : "Intimate Piano.aupreset"
        let template = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Audio/Presets/Garritan/ARIA Player/" + fileName)
        let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("Garritan-Track-" + UUID().uuidString + ".aupreset")
        defer { try? FileManager.default.removeItem(at: temp) }
        try GarritanNativePreset.generateNativePreset(
            template, temp, program.programName,
            templateName: sourceName, bankID: instant ? "2007" : "2013")
        let data = try Data(contentsOf: temp)
        guard let state = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
              state["AriaData"] is Data else {
            throw NSError(domain: "GarritanTrack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid ARIA preset"])
        }
        let component = unit.auAudioUnit.componentDescription
        for (key, expected) in [
            ("type", component.componentType),
            ("subtype", component.componentSubType),
            ("manufacturer", component.componentManufacturer)
        ] {
            guard let value = state[key] as? NSNumber,
                  value.uint32Value == expected else {
                throw NSError(domain: "GarritanTrack", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Preset does not match track plugin"])
            }
        }
        unit.auAudioUnit.fullState = state
    }
}


private enum ARIARackSlotLoader {
    enum Failure: LocalizedError {
        case invalidState, occupied, missingTemplateSlot, rejected
        var errorDescription: String? {
            switch self {
            case .invalidState: return "ARIA state could not be decoded safely."
            case .occupied: return "The selected slot already contains an instrument."
            case .missingTemplateSlot: return "The verified preset has no single instrument slot."
            case .rejected: return "ARIA did not confirm the new instrument. Previous state restored."
            }
        }
    }
    private static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        guard bytes.count > 14, Array(bytes.prefix(4)) == Array("CEGP".utf8) else { throw Failure.invalidState }
        let length = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 |
                         UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        guard length > 0 && length < 8_000_000 else { throw Failure.invalidState }
        let compressed = Array(bytes[10..<(bytes.count - 4)])
        var plain = [UInt8](repeating: 0, count: length)
        let count = compressed.withUnsafeBufferPointer { src in
            plain.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!,
                                          src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == length, let xml = String(bytes: plain, encoding: .utf8) else { throw Failure.invalidState }
        return xml
    }
    private static func encode(_ xml: String) throws -> Data {
        let input = Array(xml.utf8)
        var compressed = [UInt8](repeating: 0, count: max(1024, input.count * 2 + 128))
        let count = input.withUnsafeBufferPointer { src in
            compressed.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!,
                                          src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0 else { throw Failure.invalidState }
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in input { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let checksum = b << 16 | a
        let length = UInt32(input.count)
        var bytes = Array("CEGP".utf8)
        bytes += [UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
                  UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 24)]
        bytes += [0x78, 0x9c]
        bytes += compressed.prefix(count)
        bytes += [UInt8(truncatingIfNeeded: checksum >> 24), UInt8(truncatingIfNeeded: checksum >> 16),
                  UInt8(truncatingIfNeeded: checksum >> 8), UInt8(truncatingIfNeeded: checksum)]
        return Data(bytes)
    }
    private static func tags(_ xml: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"<Slot\b[^>]*\/>"#)
        return regex.matches(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml))
            .compactMap { Range($0.range, in: xml).map { String(xml[$0]) } }
    }
    private static func attribute(_ name: String, from tag: String) -> String? {
        let regex = try? NSRegularExpression(pattern: #"\b"# + name + #"="([^"]*)""#)
        guard let match = regex?.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
    private static func replaceAttribute(_ name: String, value: String, in tag: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\b"# + name + #"="[^"]*""#)
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard regex.firstMatch(in: tag, range: range) != nil else { throw Failure.invalidState }
        return regex.stringByReplacingMatches(in: tag, range: range,
                                               withTemplate: name + "=\"" + value + "\"")
    }
    static func load(_ program: TrackGarritanProgram, slot: Int, unit: AVAudioUnit) throws {
        guard (0..<16).contains(slot), let original = unit.auAudioUnit.fullState,
              let originalBlob = original["AriaData"] as? Data else { throw Failure.invalidState }
        let current = try decode(originalBlob)
        let existing = try tags(current)
        guard !existing.contains(where: { Int(attribute("id", from: $0) ?? "") == slot }) else {
            throw Failure.occupied
        }
        let instant = program.library == "Garritan Instant Orchestra"
        let sourceName = instant ? "Blending Textures/Evolving Orchestra" :
            "Standard/05 Keyboards/Concert Pianos/Intimate D"
        let filename = instant ? "Evolving Orchestra.aupreset" : "Intimate Piano.aupreset"
        let template = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Audio/Presets/Garritan/ARIA Player/" + filename)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Garritan-Rack-" + UUID().uuidString + ".aupreset")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try GarritanNativePreset.generateNativePreset(template, temporary, program.programName,
            templateName: sourceName, bankID: instant ? "2007" : "2013")
        let data = try Data(contentsOf: temporary)
        guard let preset = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let blob = preset["AriaData"] as? Data else { throw Failure.invalidState }
        let candidate = try tags(decode(blob))
        guard candidate.count == 1 else { throw Failure.missingTemplateSlot }
        var newTag = try replaceAttribute("id", value: String(slot), in: candidate[0])
        newTag = try replaceAttribute("channel", value: String(slot), in: newTag)
        guard let insertion = current.range(of: "<EffectSlot") ?? current.range(of: "</AriaSave>") else {
            throw Failure.invalidState
        }
        var updated = current
        updated.insert(contentsOf: "  " + newTag + "\n", at: insertion.lowerBound)
        guard XMLParser(data: Data(updated.utf8)).parse(),
              try tags(updated).count == existing.count + 1 else { throw Failure.invalidState }
        var newState = original
        newState["AriaData"] = try encode(updated)
        unit.auAudioUnit.fullState = newState
        let observed = ARIARackStateReader.inspect(unit)
        let oldIDs = Set(existing.compactMap { Int(attribute("id", from: $0) ?? "") })
        let observedIDs = Set(observed?.map(\.number) ?? [])
        guard observed?.first(where: { $0.number == slot })?.patch == program.programName,
              oldIDs.isSubset(of: observedIDs) else {
            unit.auAudioUnit.fullState = original
            throw Failure.rejected
        }
        print("[ARIA Rack] Loaded \(program.programName) into slot \(slot + 1)")
    }
}

private enum TrackGarritanCatalog {
    // Load the installed banks on first access, including when ARIA was added
    // after the track header was created. Avoid relying on SwiftUI onAppear.
    static let programs: [TrackGarritanProgram] = {
        let banks: [(library: String, path: String, prefix: String?)] = [
            ("Garritan Personal Orchestra 5",
             "/Library/Application Support/Garritan/Garritan Personal Orchestra 5/Banks/Standard/Personal Orchestra 5.bank.xml", "Standard/"),
            ("Garritan Instant Orchestra",
             "/Library/Application Support/Garritan/Garritan Instant Orchestra/Banks/Standard/Instant Orchestra.bank.xml", nil)
        ]
        let result = banks.flatMap { bank in
            GPO5BankReader.loadStandardPrograms(bankPath: bank.path, requiredPrefix: bank.prefix).map {
                TrackGarritanProgram(library: bank.library, programName: $0.name)
            }
        }
        print("[Garritan Track Menu] Catalog contains " + String(result.count) + " programs")
        return result
    }()
}
