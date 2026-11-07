import SwiftUI
import DAWCore

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

    private var instrumentsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Instruments").font(.headline)
                    Text("Shared instrument rack")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { viewModel.addRackInstrument() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add Rack Instrument")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if viewModel.project.vRack.instruments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No Rack Instruments")
                        .font(.caption)
                    Text("Click + to load a shared instrument.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.project.vRack.instruments) { instrument in
                            RackInstrumentRow(
                                instrument: instrument,
                                viewModel: viewModel,
                                isSelected: selectedRackInstrumentID == instrument.id,
                                onSelect: { selectedRackInstrumentID = instrument.id },
                                onShowBrowser: {
                                    selectedRackInstrumentID = instrument.id
                                    showPluginBrowser = true
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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
