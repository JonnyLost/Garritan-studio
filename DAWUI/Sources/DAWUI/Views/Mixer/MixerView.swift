import SwiftUI
import AVFoundation
import DAWCore

// MARK: - Mixer View

/// Mixing console view with channel strips
public struct MixerView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    
    @State private var showPluginBrowser = false
    @State private var selectedPluginSlot: (TrackID, Int)?
    @State private var showInsertSlots = true
    @State private var showMeters = true
    @State private var showMaster = true
    private let openStageWorkspace: (() -> Void)?

    public init(viewModel: ProjectViewModel, openStageWorkspace: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.openStageWorkspace = openStageWorkspace
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            StudioWorkspaceHeader(
                "Mixer",
                subtitle: "Instrument channels, levels and master output",
                symbol: "slider.vertical.3"
            ) {
                // Every track includes an independent, editable Concert Hall
                // send as well as insert slots. Stage remains the spatial editor.
                Menu {
                    Toggle("Show Insert Slots", isOn: $showInsertSlots)
                    Toggle("Show Level Meters", isOn: $showMeters)
                    Toggle("Show Master Channel", isOn: $showMaster)
                    Divider()
                    Button("Stage Sends & Reverb…") { openStageWorkspace?() }
                        .disabled(openStageWorkspace == nil)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
            }
            
            // Channel strips - left aligned
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        // Track channels
                        ForEach(viewModel.project.tracks) { track in
                            ChannelStripView(
                                track: track,
                                viewModel: viewModel,
                                isPlaying: viewModel.transportState.isPlaying,
                                showInsertSlots: showInsertSlots,
                                showMeters: showMeters,
                                onPluginSlotClick: { slotIndex in
                                    selectedPluginSlot = (track.id, slotIndex)
                                    showPluginBrowser = true
                                }
                            )

                        }
                        
                        // Production reference remains on a dedicated
                        // dry bus, outside all orchestral inserts/stems.
                        if let picture = viewModel.project.studioPicture {
                            StudioPictureGuideChannelStripView(
                                picture: picture, viewModel: viewModel)
                        }

                        // Master channel
                        if showMaster {
                            MasterChannelStripView(
                                track: viewModel.project.masterTrack,
                                viewModel: viewModel,
                                isPlaying: viewModel.transportState.isPlaying,
                                showMeters: showMeters
                            )
                        }
                    }
                    .padding(16)
                }
                
                Spacer() // Push channels to the left
            }
        }
        .background(palette.canvas)
        .tint(palette.accent)
        .sheet(isPresented: $showPluginBrowser) {
            PluginBrowserView(
                viewModel: viewModel,
                onSelect: { pluginID in
                    if let (trackID, slotIndex) = selectedPluginSlot {
                        Task {
                            await loadPlugin(pluginID, to: trackID, slot: slotIndex)
                        }
                    }
                    showPluginBrowser = false
                }
            )
            .frame(minWidth: 400, minHeight: 500)
        }
    }
    
    private func loadPlugin(_ pluginID: PluginIdentifier, to trackID: TrackID, slot slotIndex: Int) async {
        do {
            // Get audio format from engine
            let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
            
            // Load the plugin
            let loadedPlugin = try await viewModel.pluginHost.loadPlugin(
                identifier: pluginID,
                format: format
            )
            
            // Update track with plugin
            if var track = viewModel.project.track(withID: trackID) {
                // Ensure we have enough slots
                while track.pluginSlots.count <= slotIndex {
                    track.pluginSlots.append(PluginSlot())
                }
                
                track.pluginSlots[slotIndex].pluginID = pluginID
                track.pluginSlots[slotIndex].isEnabled = true
                
                viewModel.updateTrack(track, description: "Add Plugin")
                
                // Insert into audio chain
                try viewModel.audioEngine.insertPlugin(loadedPlugin.audioUnit, on: trackID, at: slotIndex)
            }
        } catch {
            print("Failed to load plugin: \(error)")
        }
    }
}

// MARK: - Channel Strip View

struct ChannelStripView: View {
    @Environment(\.studioPalette) private var palette
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let isPlaying: Bool
    let showInsertSlots: Bool
    let showMeters: Bool
    let onPluginSlotClick: (Int) -> Void
    
    private var meterLevels: (left: Float, right: Float) {
        viewModel.playbackEngine.trackMeterLevels[track.id] ?? (0, 0)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Track identity: clearly selected, with an instrument/track color key.
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: track.color.hex) ?? palette.accent)
                    .frame(height: 4)
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Text(track.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.primaryText)
                .help(track.name)
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 6)
            
            // Four initially visible inserts, with additional restored
            // slots displayed automatically. Only contiguous slots can be
            // newly populated; this preserves AudioEngine's ordered chain.
            if showInsertSlots {
                VStack(alignment: .leading, spacing: 3) {
                    Text("INSERTS")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.bottom, 2)
                    ForEach(0..<max(4, track.pluginSlots.count), id: \.self) { index in
                        let slot: PluginSlot? =
                            index < track.pluginSlots.count ? track.pluginSlots[index] : nil
                        PluginSlotView(
                            slot: slot,
                            onClick: { onPluginSlotClick(index) },
                            onOpenEditor: slot?.pluginID != nil ? {
                                viewModel.openTrackEffectUI(track.id, slotIndex: index)
                            } : nil
                        )
                        // A new insert is only added after the existing
                        // contiguous chain, never into a gap in the AU graph.
                        .disabled(slot?.pluginID == nil &&
                                  track.pluginSlots.prefix(index).filter {
                                      $0.pluginID != nil
                                  }.count != index)
                    }
                }
.padding(.horizontal, 9)
                .padding(.vertical, 6)
            }

            // Both controls retain the original live playback bindings.
            HStack(alignment: .top, spacing: 5) {
                StudioParameterKnob(
                    "Hall",
                    value: Binding(
                        get: { Double(track.stageWetTrim ?? 1) },
                        set: { viewModel.setTrackStageWetTrim(id: track.id, trim: Float($0)) }
                    ),
                    in: 0...2,
                    tint: StudioGUI.accent,
                    formattedValue: { String(format: "%.0f%%", $0 * 100) }
                )
                .accessibilityLabel("Concert Hall send for \(track.name)")

                StudioParameterKnob(
                    "Pan",
                    value: Binding(
                        get: { Double(track.pan) },
                        set: { viewModel.setTrackPan(id: track.id, pan: Float($0)) }
                    ),
                    in: -1...1,
                    formattedValue: {
                        abs($0) < 0.01 ? "C" :
                            String(format: "%.0f%@", abs($0) * 100, $0 < 0 ? "L" : "R")
                    }
                )
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 7)

            Spacer(minLength: 4)
            
            // Dedicated metering and volume section.
            HStack(spacing: 9) {
                if showMeters {
                    StereoMeterView(leftLevel: meterLevels.left, rightLevel: meterLevels.right)
                        .frame(width: 18, height: 145)
                        .accessibilityLabel("Stereo level meter for \(track.name)")
                }
                
                FaderView(
                    value: Binding(
                        get: { Double(track.volume) },
                        set: { viewModel.setTrackVolume(id: track.id, volume: Float($0)) }
                    ),
                    range: 0...1.4
                )
                .frame(width: 26, height: 145)
            }
            
            Text(volumeText + " dB")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.primaryText)
                .padding(.top, 4)
                .padding(.bottom, 8)
            
            // Solo/Mute
            HStack(spacing: 4) {
                Button(action: { viewModel.toggleTrackSolo(id: track.id) }) {
                    Text("S")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(track.isSolo ? .black : .secondary)
                        .frame(width: 22, height: 18)
                        .background(track.isSolo ? Color.yellow : Color.gray.opacity(0.3))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.toggleTrackMute(id: track.id) }) {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(track.isMuted ? .black : .secondary)
                        .frame(width: 22, height: 18)
                        .background(track.isMuted ? Color.orange : Color.gray.opacity(0.3))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 166, height: 455)
        .background(isSelected ? palette.selectedBackground.opacity(0.6) : palette.panel)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? palette.accent : palette.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            // Instant selection with piano roll follow (no animation delay)
            withAnimation(.none) {
                viewModel.selectAndArmTrack(track.id)
            }
        }
    }
    
    private var isSelected: Bool {
        viewModel.selectedTrackID == track.id
    }
    
    private var volumeText: String {
        let db = 20 * log10(track.volume)
        if db == -.infinity { return "-∞" }
        return String(format: "%.1f", db)
    }
    
}


//// MARK: - Picture Guide Audio Return

private struct StudioPictureGuideChannelStripView: View {
    @Environment(\.studioPalette) private var palette
    let picture: StudioPictureProject
    @ObservedObject var viewModel: ProjectViewModel

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.orange)
                .frame(height: 4)
            Image(systemName: "film")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
                .padding(.top, 4)
            Text("PICTURE")
                .font(.system(size: 10, weight: .bold))
            Text("Guide Audio")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text("DRY")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("No hall send")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)

            Spacer(minLength: 8)

            FaderView(value: Binding(
                get: { Double(picture.referenceAudioVolume ?? 0.65) },
                set: { level in
                    var current = viewModel.project.studioPicture
                    current?.referenceAudioVolume = Float(level)
                    viewModel.project.studioPicture = current
                }
            ), range: 0...1)
            .frame(width: 26, height: 145)
            .disabled(!picture.referenceAudioEnabled)

            Text(String(format: "%.0f%%", (picture.referenceAudioVolume ?? 0.65) * 100))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                var current = viewModel.project.studioPicture
                current?.referenceAudioEnabled.toggle()
                viewModel.project.studioPicture = current
            } label: {
                Text("M")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(picture.referenceAudioEnabled ? .secondary : .black)
                    .frame(width: 22, height: 18)
                    .background(picture.referenceAudioEnabled
                        ? Color.gray.opacity(0.3) : Color.orange)
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .help(picture.referenceAudioEnabled ? "Mute picture guide" : "Unmute picture guide")
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 7)
        .frame(width: 110, height: 455)
        .background(palette.panel)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.65), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture guide audio channel")
    }
}

// MARK: - Master Channel Strip View

struct MasterChannelStripView: View {
    @Environment(\.studioPalette) private var palette
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let isPlaying: Bool
    let showMeters: Bool
    
    private var meterLevels: (left: Float, right: Float) {
        viewModel.playbackEngine.masterMeterLevel
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Master label
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.accent)
                    .frame(height: 4)
                
                Text("MASTER")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            
            Spacer(minLength: 8)
            
            // Meter and fader
            HStack(spacing: 4) {
                if showMeters {
                    StereoMeterView(leftLevel: meterLevels.left, rightLevel: meterLevels.right)
                        .frame(width: 17, height: 170)
                }
                
                FaderView(
                    value: Binding(
                        get: { Double(viewModel.audioEngine.masterVolume) },
                        set: { viewModel.audioEngine.setMasterVolume(Float($0)) }
                    ),
                    range: 0...1.4
                )
                .frame(width: 26, height: 170)
            }
            
            Text(masterVolumeText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .frame(width: 104, height: 335)
        .background(palette.raisedSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.accent.opacity(0.65), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var masterVolumeText: String {
        let db = 20 * log10(viewModel.audioEngine.masterVolume)
        if db == -.infinity { return "-∞ dB" }
        return String(format: "%.1f dB", db)
    }
}

// MARK: - Plugin Slot View

struct PluginSlotView: View {
    @Environment(\.studioPalette) private var palette
    let slot: PluginSlot?
    let onClick: () -> Void
    let onOpenEditor: (() -> Void)?

    init(slot: PluginSlot?, onClick: @escaping () -> Void, onOpenEditor: (() -> Void)? = nil) {
        self.slot = slot
        self.onClick = onClick
        self.onOpenEditor = onOpenEditor
    }

    private var isOccupied: Bool { slot?.pluginID != nil }

    var body: some View {
        Button {
            if isOccupied, let onOpenEditor {
                onOpenEditor()
            } else {
                onClick()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOccupied ? "slider.horizontal.3" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOccupied ? palette.accent : palette.secondaryText)

                Text(slot?.pluginID?.name ?? "Add Effect")
                    .font(.system(size: 10, weight: isOccupied ? .medium : .regular))
                    .foregroundStyle(isOccupied ? palette.primaryText : palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if isOccupied {
                    Circle()
                        .fill(slot?.isEnabled == true ? StudioGUI.activity : palette.secondaryText)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(palette.separator.opacity(0.65), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOccupied ? "Open effect editor" : "Add an effect to this insert")
        .accessibilityLabel(isOccupied ? "Effect: \(slot?.pluginID?.name ?? "Plugin")" : "Add effect")
        .contextMenu {
            if isOccupied {
                Button("Open Editor") { onOpenEditor?() }
            }
        }
    }
}

// MARK: - Fader View

struct FaderView: View {
    @Environment(\.studioPalette) private var palette
    @Binding var value: Double
    let range: ClosedRange<Double>
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 6)
                
                // Fill
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.accent.opacity(0.5))
                        .frame(width: 6, height: fillHeight(in: geometry.size.height))
                }
                
                // Handle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 20, height: 12)
                    .shadow(radius: 1)
                    .offset(y: handleOffset(in: geometry.size.height))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let normalized = 1.0 - (gesture.location.y / geometry.size.height)
                        let clamped = max(0, min(1, normalized))
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
    
    private func normalizedValue() -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    
    private func fillHeight(in totalHeight: CGFloat) -> CGFloat {
        CGFloat(normalizedValue()) * totalHeight
    }
    
    private func handleOffset(in totalHeight: CGFloat) -> CGFloat {
        let normalized = normalizedValue()
        return (1.0 - CGFloat(normalized)) * totalHeight - totalHeight / 2
    }
}

// MARK: - Knob View

struct KnobView: View {
    @Environment(\.studioPalette) private var palette
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Knob background
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 30, height: 30)
                
                // Indicator
                Circle()
                    .trim(from: 0, to: 0.75)
                    .rotation(.degrees(135))
                    .stroke(palette.accent, lineWidth: 3)
                    .frame(width: 26, height: 26)
                
                // Position indicator
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 10)
                    .offset(y: -8)
                    .rotationEffect(.degrees(indicatorAngle))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let delta = -gesture.translation.height / 100
                        let normalized = normalizedValue() + delta
                        let clamped = max(0, min(1, normalized))
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
            )
            
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
    
    private func normalizedValue() -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    
    private var indicatorAngle: Double {
        -135 + normalizedValue() * 270
    }
}

// MARK: - Stereo Meter View

struct StereoMeterView: View {
    let leftLevel: Float
    let rightLevel: Float
    
    var body: some View {
        HStack(spacing: 2) {
            MeterChannelView(level: leftLevel)
            MeterChannelView(level: rightLevel)
        }
    }
}

struct MeterChannelView: View {
    let level: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                Rectangle()
                    .fill(Color.black)
                
                // Meter segments
                VStack(spacing: 1) {
                    // Red zone (top 10%)
                    Rectangle()
                        .fill(level > 0.9 ? Color.red : Color.red.opacity(0.2))
                        .frame(height: geometry.size.height * 0.1)
                    
                    // Yellow zone (next 20%)
                    Rectangle()
                        .fill(level > 0.7 ? Color.yellow : Color.yellow.opacity(0.2))
                        .frame(height: geometry.size.height * 0.2)
                    
                    // Green zone (bottom 70%)
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.green.opacity(0.2))
                        
                        if level > 0 {
                            Rectangle()
                                .fill(Color.green)
                                .frame(height: max(0, CGFloat(min(level, 0.7)) / 0.7 * geometry.size.height * 0.7))
                        }
                    }
                    .frame(height: geometry.size.height * 0.7)
                }
            }
            .cornerRadius(2)
        }
    }
}

// MARK: - Plugin Browser View

struct PluginBrowserView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let onSelect: (PluginIdentifier) -> Void
    
    @State private var searchText = ""
    @State private var selectedCategory: PluginCategory = .all
    @State private var isScanning = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Plugins")
                    .font(.headline)
                
                Spacer()
                
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Button("Rescan") {
                    isScanning = true
                    Task {
                        await viewModel.pluginHost.scanForPlugins()
                        isScanning = false
                    }
                }
                .disabled(isScanning)
            }
            .padding()
            
            Divider()
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search plugins...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Category tabs
            Picker("Category", selection: $selectedCategory) {
                Text("All").tag(PluginCategory.all)
                Text("Effects").tag(PluginCategory.effects)
                Text("Instruments").tag(PluginCategory.instruments)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            Divider()
            
            // Plugin list
            if filteredEffects.isEmpty && filteredInstruments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No plugins found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Click Rescan to search for Audio Unit plugins")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Scan for Plugins") {
                        isScanning = true
                        Task {
                            await viewModel.pluginHost.scanForPlugins()
                            isScanning = false
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    if (selectedCategory == .all || selectedCategory == .effects) && !filteredEffects.isEmpty {
                        Section("Effects (\(filteredEffects.count))") {
                            ForEach(filteredEffects) { plugin in
                                PluginRowView(plugin: plugin, isInstrument: false, onSelect: {
                                    onSelect(plugin.identifier)
                                })
                            }
                        }
                    }
                    
                    if (selectedCategory == .all || selectedCategory == .instruments) && !filteredInstruments.isEmpty {
                        Section("Instruments (\(filteredInstruments.count))") {
                            ForEach(filteredInstruments) { plugin in
                                PluginRowView(plugin: plugin, isInstrument: true, onSelect: {
                                    onSelect(plugin.identifier)
                                })
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if viewModel.pluginHost.availableEffects.isEmpty && viewModel.pluginHost.availableInstruments.isEmpty {
                isScanning = true
                Task {
                    await viewModel.pluginHost.scanForPlugins()
                    isScanning = false
                }
            }
        }
    }
    
    private var filteredEffects: [PluginDescription] {
        viewModel.pluginHost.availableEffects.filter { plugin in
            searchText.isEmpty || plugin.identifier.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private var filteredInstruments: [PluginDescription] {
        viewModel.pluginHost.availableInstruments.filter { plugin in
            searchText.isEmpty || plugin.identifier.name.localizedCaseInsensitiveContains(searchText)
        }
    }
}

enum PluginCategory {
    case all
    case effects
    case instruments
}

struct PluginRowView: View {
    let plugin: PluginDescription
    let isInstrument: Bool
    let onSelect: () -> Void
    
    init(plugin: PluginDescription, isInstrument: Bool = false, onSelect: @escaping () -> Void) {
        self.plugin = plugin
        self.isInstrument = isInstrument
        self.onSelect = onSelect
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                // Plugin icon based on type
                Image(systemName: isInstrument ? "pianokeys" : "waveform")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.identifier.name)
                        .font(.system(size: 12, weight: .medium))
                    
                    Text(plugin.identifier.manufacturer)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(plugin.version)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
