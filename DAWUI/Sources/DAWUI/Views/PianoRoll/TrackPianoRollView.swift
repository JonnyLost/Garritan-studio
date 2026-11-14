import SwiftUI
import DAWCore

// MARK: - Scroll Offset Tracking

/// PreferenceKey to track vertical scroll offset for synchronization
private struct VerticalScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// PreferenceKey to track horizontal scroll offset for synchronization
private struct HorizontalScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Track-Based Piano Roll View

/// A piano roll that shows ALL MIDI on a track, not tied to individual clips.
/// Auto-creates a master clip when the user draws notes on an empty track.
public struct TrackPianoRollView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    
    // Editor state
    @State private var currentTool: MIDIEditorTool = .select
    @State private var snapMode: SnapMode = .sixteenth
    @State private var showVelocityLane: Bool = true
    @State private var showCCLane: Bool = false
    @State private var showArticulationLane = false
    @State private var showArticulationMapEditor = false
    private let articulationLaneHeight: CGFloat = 42
    @State private var selectedCCType: CCType = .modulation
    @State private var expressionChannel = 0
    @State private var expressionStroke: [StudioMIDIExpressionPoint] = []
    @State private var expressionTargetClipID: ClipID? = nil
    @State private var expressionNewClip: Clip? = nil
    @State private var keyswitchPitch = 24
    @State private var showKeyswitchControls = false
    
    // Selection state
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var selectionRect: CGRect? = nil
    @State private var isMarqueeSelecting: Bool = false
    @State private var didToggleShiftNote = false
    @State private var eraserPendingIDs: Set<UUID> = []
    @State private var velocityEditID: UUID? = nil
    @State private var velocityDragStart = 100
    @State private var velocityHasChanged = false
    
    // Pencil tool preview state
    @State private var pencilPreviewStart: Double? = nil
    @State private var pencilPreviewPitch: Int? = nil
    @State private var pencilPreviewDuration: Double = 0

    // Editing state
    @State private var draggedNoteID: UUID? = nil
    // Keep preview changes local until release, so Undo captures real originals.
    @State private var previewTrack: Track? = nil
    @State private var dragHasMaterialChange = false
    @State private var dragMode: NoteDragMode = .none
    @State private var dragStartBeat: Double = 0
    @State private var dragStartPitch: Int = 0
    @State private var dragStartDuration: Double = 0
    
    // Current drag delta (for visual feedback during drag)
    @State private var currentDragBeatDelta: Double = 0
    @State private var currentDragPitchDelta: Int = 0

    // Multi-select drag state
    @State private var dragStartPositions: [UUID: (beat: Double, pitch: Int, duration: Double)] = [:]
    
    // Note audition during drag
    @State private var lastAuditionedPitch: Int? = nil
    @State private var pressedCanvasPitch: Int? = nil
    
    // Modifier key states
    @State private var isCopyingNotes: Bool = false
    
    // Dialogs
    @State private var showQuantizeDialog: Bool = false
    @State private var showOffsetDialog: Bool = false
    
    // Focus state for keyboard events
    @FocusState private var isViewFocused: Bool

    // View state
    @State private var pixelsPerBeat: Double = 60
    @State private var noteHeight: CGFloat = 14
    @State private var visibleOctaveRange: ClosedRange<Int> = 2...7
    
    // Copied notes for paste
    @State private var copiedNotes: [MIDIEvent] = []
    @State private var copiedArticulations: [UUID: String] = [:]
    
    // Playhead position
    @State private var currentPlayheadBeat: Double = 0
    
    // Track color for notes
    private var trackColor: Color {
        if let track = viewModel.project.track(withID: trackID) {
            return Color(hex: track.color.hex) ?? .accentColor
        }
        return .accentColor
    }
    
    private let pianoKeyWidth: CGFloat = 60
    private let velocityLaneHeight: CGFloat = 80
    private let ccLaneHeight: CGFloat = 80
    
    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }
    
    // MARK: - Computed Properties
    
    /// Get the current track
    private var currentTrack: Track? {
        viewModel.project.track(withID: trackID)
    }
    
    /// Get or create the master clip for this track
    private var masterClip: Clip? {
        guard let track = currentTrack else { return nil }
        // Return the first MIDI clip (acts as master)
        return track.clips.first(where: { $0.content.isMIDI })
    }
    
    /// All note events from all clips on this track (with absolute beat positions)
    private var noteEvents: [MIDIEvent] {
        guard let track = previewTrack ?? currentTrack else { return [] }
        
        var allNotes: [MIDIEvent] = []
        for clip in track.clips {
            if case .midi(let midiData) = clip.content {
                let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                for event in midiData.events {
                    if case .note = event.type {
                        // Convert to absolute beat position
                        var absoluteEvent = event
                        absoluteEvent.beatPosition = clipStartBeat + event.beatPosition
                        allNotes.append(absoluteEvent)
                    }
                }
            }
        }
        return allNotes
    }
    
    /// All CC events from all clips on this track
    private var ccEvents: [MIDIEvent] {
        guard let track = previewTrack ?? currentTrack else { return [] }
        
        var allCC: [MIDIEvent] = []
        for clip in track.clips {
            if case .midi(let midiData) = clip.content {
                let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                for event in midiData.events {
                    if StudioMIDIExpressionEditing.normalizedValue(
                        of: event, for: selectedCCType,
                        channel: UInt8(expressionChannel)) != nil {
                        var absoluteEvent = event
                        absoluteEvent.beatPosition = clipStartBeat + event.beatPosition
                        allCC.append(absoluteEvent)
                    }
                }
            }
        }
        return allCC
    }
    
    private var articulationAssignments: [UUID: String] {
        guard let track = previewTrack ?? currentTrack else { return [:] }
        var assignments: [UUID: String] = [:]
        for clip in track.clips {
            guard case .midi(let midi) = clip.content else { continue }
            assignments.merge(StudioArticulationAssignmentEditing.byNoteID(in: midi),
                              uniquingKeysWith: { _, last in last })
        }
        return assignments
    }

    private var pitchOffset: Int {
        visibleOctaveRange.upperBound * 12 + 11
    }
    
    private var totalHeight: CGFloat {
        CGFloat((visibleOctaveRange.count) * 12) * noteHeight
    }
    
    private var totalWidth: CGFloat {
        // Show at least 32 bars worth
        let minBeats = 32.0 * 4.0
        let trackEndBeat = noteEvents.map { event -> Double in
            if case .note(let data) = event.type {
                return event.beatPosition + data.duration
            }
            return event.beatPosition
        }.max() ?? 0
        return CGFloat(max(minBeats, trackEndBeat + 16)) * pixelsPerBeat
    }
    
    private var playheadX: CGFloat {
        CGFloat(currentPlayheadBeat) * pixelsPerBeat
    }
    
    // MARK: - Body
    
    // Track scroll offsets for synchronization
    @State private var horizontalScrollOffset: CGFloat = 0
    
    public var body: some View {
        VStack(spacing: 0) {
            StudioWorkspaceHeader(
                "Piano Roll",
                subtitle: "MIDI note editor, velocity and expression lanes",
                symbol: "pianokeys"
            ) {
                if let track = currentTrack {
                    Text(track.name)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            editorToolbar
            
            Rectangle().fill(palette.separator).frame(height: 1)
            
            GeometryReader { geometry in
                let availableHeight = geometry.size.height - (showVelocityLane ? velocityLaneHeight : 0) - (showCCLane ? ccLaneHeight : 0) - (showArticulationLane ? articulationLaneHeight : 0) - 24
                let visibleWidth = geometry.size.width - pianoKeyWidth
                
                VStack(spacing: 0) {
                    // TOP ROW: Corner + Bar ruler (synced with note grid horizontal scroll)
                    HStack(spacing: 0) {
                        palette.panel
                            .frame(width: pianoKeyWidth, height: 24)
                        
                        // Bar ruler - offset to match note grid horizontal scroll
                        barRulerCanvas
                            .frame(width: totalWidth, height: 24)
                            .offset(x: horizontalScrollOffset)
                            .frame(width: visibleWidth, alignment: .leading)
                            .clipped()
                    }
                    .frame(height: 24)
                    
                    // MIDDLE ROW: Piano keys + Note grid (SAME vertical scroll)
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            // Piano keys
                            pianoKeysCanvas
                                .frame(width: pianoKeyWidth, height: totalHeight)
                            
                            // Note grid (horizontal scroll inside) - tracks position
                            ScrollView(.horizontal, showsIndicators: true) {
                                noteGridCanvas
                                    .frame(width: totalWidth, height: totalHeight)
                                    .background(
                                        GeometryReader { innerGeo in
                                            Color.clear.preference(
                                                key: HorizontalScrollOffsetKey.self,
                                                value: innerGeo.frame(in: .named("noteGridHorizontalScroll")).minX
                                            )
                                        }
                                    )
                            }
                            .coordinateSpace(name: "noteGridHorizontalScroll")
                            .onPreferenceChange(HorizontalScrollOffsetKey.self) { offset in
                                horizontalScrollOffset = offset
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .frame(height: availableHeight)
                    .focusEffectDisabled()
                    
                    // BOTTOM ROW: Labels + Velocity/CC (synced with note grid horizontal scroll)
                    if showVelocityLane {
                        HStack(spacing: 0) {
                            Text("Vel")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: velocityLaneHeight)
                                .background(palette.panel)
                            
                            // Velocity - offset to match note grid horizontal scroll
                            velocityCanvas
                                .frame(width: totalWidth, height: velocityLaneHeight)
                                .offset(x: horizontalScrollOffset)
                                .frame(width: visibleWidth, alignment: .leading)
                                .clipped()
                        }
                        .frame(height: velocityLaneHeight)
                    }
                    
                    if showCCLane {
                        HStack(spacing: 0) {
                            Text(selectedCCType.name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: ccLaneHeight)
                                .background(palette.panel)
                            
                            // CC - offset to match note grid horizontal scroll
                            ccCanvas
                                .frame(width: totalWidth, height: ccLaneHeight)
                                .offset(x: horizontalScrollOffset)
                                .frame(width: visibleWidth, alignment: .leading)
                                .clipped()
                        }
                        .frame(height: ccLaneHeight)
                    }

                    if showArticulationLane {
                        HStack(spacing: 0) {
                            Text("Art")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: articulationLaneHeight)
                                .background(palette.panel)

                            StudioArticulationLane(
                                notes: noteEvents,
                                assignments: articulationAssignments,
                                map: currentTrack?.articulationMap,
                                pixelsPerBeat: pixelsPerBeat,
                                width: totalWidth,
                                height: articulationLaneHeight,
                                onAssign: { noteID, articulationID in
                                    assignArticulation(articulationID, to: [noteID])
                                }
                            )
                            .offset(x: horizontalScrollOffset)
                            .frame(width: visibleWidth, alignment: .leading)
                            .clipped()
                        }
                        .frame(height: articulationLaneHeight)
                    }
                }
            }
        }
        .background(palette.canvas)
        .tint(palette.accent)
        .focusable()
        .focused($isViewFocused)
        .focusEffectDisabled()
        .onKeyPress { keyPress in
            if keyPress.modifiers.contains(.command) {
                switch keyPress.characters.lowercased() {
                case "a": selectAllNotes(); return .handled
                case "c": copySelectedNotes(); return .handled
                case "x": copySelectedNotes(); deleteSelectedNotes(); return .handled
                case "v": pasteNotes(); return .handled
                case "d": duplicateSelectedNotes(); return .handled
                default: break
                }
            }
            // CMD + Arrow keys for zoom
            if keyPress.modifiers.contains(.command) {
                switch keyPress.key {
                case .leftArrow:
                    zoomHorizontal(zoomIn: false)
                    return .handled
                case .rightArrow:
                    zoomHorizontal(zoomIn: true)
                    return .handled
                case .upArrow:
                    zoomVertical(zoomIn: true)
                    return .handled
                case .downArrow:
                    zoomVertical(zoomIn: false)
                    return .handled
                default:
                    break
                }
            }
            
            // Delete key - delete selected notes (backspace, delete, fn+delete)
            let isDeleteKey = keyPress.key == .delete || 
                              keyPress.key == .deleteForward ||
                              keyPress.characters == "\u{7F}" ||  // Backspace (ASCII 127)
                              keyPress.characters == "\u{08}"     // Backspace (ASCII 8)
            if isDeleteKey {
                if !selectedNoteIDs.isEmpty {
                    deleteSelectedNotes()
                    return .handled
                }
            }
            
            // Tool shortcuts (without modifiers)
            switch keyPress.characters.lowercased() {
            case "a": currentTool = .select; return .handled
            case "p": currentTool = .pencil; return .handled
            case "e": currentTool = .eraser; return .handled
            case "v": currentTool = .velocity; return .handled
            case "q":
                if !selectedNoteIDs.isEmpty { showQuantizeDialog = true }
                return .handled
            default: return .ignored
            }
        }
        .onAppear {
            visibleOctaveRange = 2...7
            currentPlayheadBeat = viewModel.transportState.smoothPlayheadBeats
        }
        .onReceive(viewModel.transportState.$smoothPlayheadBeats) { beats in
            currentPlayheadBeat = beats
        }
        .sheet(isPresented: $showQuantizeDialog) {
            QuantizeDialogView(
                noteCount: selectedNoteIDs.count,
                onQuantize: { grid in quantizeSelectedNotes(to: grid) },
                onCancel: { showQuantizeDialog = false }
            )
        }
        .sheet(isPresented: $showOffsetDialog) {
            OffsetDialogView(
                noteCount: selectedNoteIDs.count,
                tempo: viewModel.transportState.tempo.bpm,
                onApply: { ms in applyOffset(milliseconds: ms); showOffsetDialog = false },
                onCancel: { showOffsetDialog = false }
            )
        }
        .sheet(isPresented: $showArticulationMapEditor) {
            StudioArticulationMapEditor(
                map: currentTrack?.articulationMap,
                garritanProgramID: currentTrack?.garritanProgramID
            ) { map in
                guard var track = currentTrack else { return }
                track.articulationMap = map
                viewModel.updateTrack(track, description: "Edit Articulation Map")
                showArticulationLane = true
            }
        }
    }
    
    // MARK: - Toolbar
    
    private var editorToolbar: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.closePianoRoll() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            
            Divider().frame(height: 20)
            
            ForEach([MIDIEditorTool.select, .pencil, .eraser, .velocity], id: \.self) { tool in
                Button(action: { currentTool = tool }) {
                    Image(systemName: tool.icon)
                        .foregroundColor(currentTool == tool ? palette.accent : palette.primaryText)
                        .frame(width: 26, height: 26)
                        .background(currentTool == tool ? palette.selectedBackground : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("\(tool.rawValue) (\(tool.shortcutKey))")
            }
            
            Divider().frame(height: 20)
            
            HStack(spacing: 4) {
                Text("Snap:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("", selection: $snapMode) {
                    ForEach(SnapMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }
            
            Divider().frame(height: 20)
            
            Button("Quantize") { showQuantizeDialog = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)
            
            Button("Offset") { showOffsetDialog = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)
            
            HStack(spacing: 5) {
                Button(action: selectAllNotes) {
                    Image(systemName: "checkmark.square")
                }.help("Select All Notes (⌘A)")
                Button(action: copySelectedNotes) {
                    Image(systemName: "doc.on.doc")
                }.disabled(selectedNoteIDs.isEmpty).help("Copy Notes (⌘C)")
                Button(action: pasteNotes) {
                    Image(systemName: "doc.on.clipboard")
                }.disabled(copiedNotes.isEmpty).help("Paste Notes (⌘V)")
                Button(action: duplicateSelectedNotes) {
                    Image(systemName: "plus.square.on.square")
                }.disabled(selectedNoteIDs.isEmpty).help("Duplicate Notes (⌘D)")
                Button(action: deleteSelectedNotes) {
                    Image(systemName: "trash")
                }.disabled(selectedNoteIDs.isEmpty).help("Delete Notes")
            }
            .buttonStyle(.plain)

            Spacer()
            
            // Zoom controls
            HStack(spacing: 4) {
                Text("H:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { zoomHorizontal(zoomIn: false) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom Out Horizontal (⌘←)")
                Button(action: { zoomHorizontal(zoomIn: true) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom In Horizontal (⌘→)")
            }
            
            HStack(spacing: 4) {
                Text("V:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { zoomVertical(zoomIn: false) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom Out Vertical (⌘↓)")
                Button(action: { zoomVertical(zoomIn: true) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom In Vertical (⌘↑)")
            }
            
            Divider().frame(height: 20)
            
            Toggle("Velocity", isOn: $showVelocityLane)
                .toggleStyle(.checkbox)
                .font(.caption)
            
            Toggle("CC", isOn: $showCCLane)
                .toggleStyle(.checkbox)
                .font(.caption)
            
            if showCCLane {
                Picker("", selection: $selectedCCType) {
                    ForEach(CCType.allCases) { cc in
                        Text(cc.name).tag(cc)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 125)
            }

            Picker("Ch", selection: $expressionChannel) {
                ForEach(0..<16, id: \.self) { channel in
                    Text("\(channel + 1)").tag(channel)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 75)
            .help("MIDI channel for expression and keyswitch input")

            Toggle("Art", isOn: $showArticulationLane)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show note articulation assignments")

            Menu("Articulation") {
                if let map = currentTrack?.articulationMap {
                    ForEach(map.articulations) { definition in
                        Button(definition.name) {
                            assignArticulation(definition.id, to: selectedNoteIDs)
                        }
                        .disabled(selectedNoteIDs.isEmpty)
                    }
                    Divider()
                    Button("Clear Selected") {
                        assignArticulation(nil, to: selectedNoteIDs)
                    }
                    .disabled(selectedNoteIDs.isEmpty)
                    Divider()
                }
                Button("Edit Articulation Map…") {
                    showArticulationMapEditor = true
                }
            }
            .help("Apply a musical articulation to selected notes or configure the track map")

            Button("Keyswitch") { showKeyswitchControls = true }
                .buttonStyle(.bordered)
                .help("Insert an instrument-specific articulation keyswitch note")
                .popover(isPresented: $showKeyswitchControls) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Insert Articulation Keyswitch").font(.headline)
                        Text("Choose the trigger note used by your instrument. Keys are not mapped automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("Trigger: \(NoteData(pitch: UInt8(keyswitchPitch)).noteName) (\(keyswitchPitch))",
                                value: $keyswitchPitch, in: 0...127)
                        Button("Insert at Playhead") {
                            insertKeyswitch()
                            showKeyswitchControls = false
                        }
                    }
                    .padding()
                    .frame(width: 300)
                }

            // Track name
            if let track = currentTrack {
                Text(track.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }
    
    // MARK: - Bar Ruler Canvas
    
    private var barRulerCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = StudioMusicalGrid.beatsPerBar(timeSignature)
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(Color.gray.opacity(0.3)), lineWidth: 0.5)
            }
            for bar in 0...Int(ceil(Double(totalBeats) / beatsPerBar)) {
                let x = Double(bar) * beatsPerBar * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
                let text = Text("\(bar + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                context.draw(text, at: CGPoint(x: x + 8, y: size.height / 2))
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
        }
        .background(palette.panel)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let beat = max(0, value.location.x / pixelsPerBeat)
                    viewModel.transportState.setPlayheadBeats(beat)
                    currentPlayheadBeat = beat
                }
        )
    }
    
    // MARK: - Note Grid Canvas
    
    /// Check if we're recording on this track
    private var isRecordingOnThisTrack: Bool {
        viewModel.isRecording && viewModel.recordingTrackID == trackID
    }
    
    /// Get live recorded events for display
    private var liveRecordedEvents: [MIDIEvent] {
        viewModel.midiRecorder.liveRecordedEvents
    }
    
    /// Get the beat position where recording started
    private var liveRecordingStartBeat: Double {
        viewModel.midiRecorder.liveRecordingStartBeat
    }
    
    private var noteGridCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = StudioMusicalGrid.beatsPerBar(timeSignature)
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            let pitchRange = visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11
            
            // Horizontal lines (pitch rows)
            for (index, pitch) in pitchRange.reversed().enumerated() {
                let y = Double(index) * Double(noteHeight)
                let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
                
                if isBlackKey {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: Double(noteHeight))
                    context.fill(Path(rect), with: .color(palette.appearance == .heritageLight ?
                        Color.black.opacity(0.05) : Color.white.opacity(0.04)))
                }
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(linePath, with: .color(palette.separator.opacity(pitch % 12 == 0 ? 0.65 : 0.25)), lineWidth: pitch % 12 == 0 ? 1 : 0.5)
            }
            
            // Draw quarter-note beats and true measure boundaries independently.
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(palette.separator.opacity(0.35)), lineWidth: 0.5)
            }
            for bar in 0...Int(ceil(Double(totalBeats) / beatsPerBar)) {
                let x = Double(bar) * beatsPerBar * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(palette.separator.opacity(0.9)), lineWidth: 1)
            }
            
            // Draw existing notes (with drag offset for selected notes being dragged)
            for event in noteEvents where !eraserPendingIDs.contains(event.id) {
                if case .note(let noteData) = event.type {
                    let noteX = event.beatPosition * pixelsPerBeat
                    let notePitch = Int(noteData.pitch)
                    let isSelected = selectedNoteIDs.contains(event.id)
                    
                    // Positions and lengths already come from previewTrack.
                    
                    let noteY = Double(pitchOffset - notePitch) * Double(noteHeight)
                    let noteWidth = max(4, noteData.duration * pixelsPerBeat)
                    
                    let noteRect = CGRect(x: noteX, y: noteY + 1, width: noteWidth, height: Double(noteHeight) - 2)
                    let notePath = Path(roundedRect: noteRect, cornerRadius: 2)
                    
                    context.fill(notePath, with: .color(trackColor))
                    context.fill(notePath, with: .color(Color.white.opacity(Double(noteData.velocity) / 127.0 * 0.3)))
                    
                    if isSelected {
                        context.stroke(notePath, with: .color(Color.white), lineWidth: 1.5)
                    }
                }
            }
            
            // Pencil gestures provide immediate note-length and pitch feedback
            // before the edit is committed to the undo history.
            if currentTool == .pencil,
               let start = pencilPreviewStart,
               let pitch = pencilPreviewPitch {
                let x = start * pixelsPerBeat
                let y = Double(pitchOffset - pitch) * Double(noteHeight)
                let preview = CGRect(x: x, y: y + 1,
                    width: max(4, pencilPreviewDuration * pixelsPerBeat),
                    height: Double(noteHeight) - 2)
                context.fill(Path(roundedRect: preview, cornerRadius: 2),
                             with: .color(trackColor.opacity(0.65)))
            }

            // Draw LIVE recording notes (in real-time as they're played)
            if isRecordingOnThisTrack {
                let recordStartX = liveRecordingStartBeat * pixelsPerBeat
                
                for event in liveRecordedEvents {
                    if case .note(let noteData) = event.type {
                        // Live events have positions relative to recording start
                        let noteX = recordStartX + (event.beatPosition * pixelsPerBeat)
                        let noteY = Double(pitchOffset - Int(noteData.pitch)) * Double(noteHeight)
                        let noteWidth = max(4, noteData.duration * pixelsPerBeat)
                        
                        let noteRect = CGRect(x: noteX, y: noteY + 1, width: noteWidth, height: Double(noteHeight) - 2)
                        let notePath = Path(roundedRect: noteRect, cornerRadius: 2)
                        
                        // Live notes: brighter color
                        context.fill(notePath, with: .color(trackColor))
                        context.fill(notePath, with: .color(Color.white.opacity(0.4)))
                    }
                }
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
            
            // Draw selection rectangle (marquee)
            if isMarqueeSelecting, let rect = selectionRect {
                let selectionPath = Path(rect)
                context.fill(selectionPath, with: .color(Color.blue.opacity(0.2)))
                context.stroke(selectionPath, with: .color(Color.blue.opacity(0.8)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(noteEditingGesture)
    }
    
    // MARK: - Velocity Canvas
    
    private var velocityCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = StudioMusicalGrid.beatsPerBar(timeSignature)
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            
            // Quarter-note beat lines plus compound-meter bar boundaries.
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(Color.gray.opacity(0.2)), lineWidth: 0.5)
            }
            for bar in 0...Int(ceil(Double(totalBeats) / beatsPerBar)) {
                let x = Double(bar) * beatsPerBar * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
            }
            
            // Velocity bars for existing notes
            for event in noteEvents {
                if case .note(let noteData) = event.type {
                    let barX = event.beatPosition * pixelsPerBeat
                    let barHeight = (Double(noteData.velocity) / 127.0) * (size.height - 4)
                    let barY = size.height - barHeight
                    let isSelected = selectedNoteIDs.contains(event.id)
                    
                    let barRect = CGRect(x: barX - 2, y: barY, width: 4, height: barHeight)
                    context.fill(Path(barRect), with: .color(isSelected ? Color.accentColor : trackColor))
                }
            }
            
            // Velocity bars for LIVE recording notes
            if isRecordingOnThisTrack {
                let recordStartX = liveRecordingStartBeat * pixelsPerBeat
                
                for event in liveRecordedEvents {
                    if case .note(let noteData) = event.type {
                        let barX = recordStartX + (event.beatPosition * pixelsPerBeat)
                        let barHeight = (Double(noteData.velocity) / 127.0) * (size.height - 4)
                        let barY = size.height - barHeight
                        
                        let barRect = CGRect(x: barX - 2, y: barY, width: 4, height: barHeight)
                        context.fill(Path(barRect), with: .color(trackColor))
                    }
                }
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
        }
        .background(Color.black.opacity(0.15))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    previewVelocityEdit(startX: value.startLocation.x, y: value.location.y)
                }
                .onEnded { _ in
                    if velocityHasChanged, let changed = previewTrack {
                        viewModel.updateTrack(changed, description: "Edit MIDI Velocity")
                    }
                    previewTrack = nil
                    velocityEditID = nil
                    velocityHasChanged = false
                }
        )
    }

    private func previewVelocityEdit(startX: CGFloat, y: CGFloat) {
        guard let original = currentTrack else { return }
        if velocityEditID == nil {
            guard let nearest = noteEvents.min(by: {
                abs($0.beatPosition * pixelsPerBeat - Double(startX)) <
                abs($1.beatPosition * pixelsPerBeat - Double(startX))
            }), abs(nearest.beatPosition * pixelsPerBeat - Double(startX)) <= 8,
                  case .note(let data) = nearest.type else { return }
            velocityEditID = nearest.id
            velocityDragStart = Int(data.velocity)
            if !selectedNoteIDs.contains(nearest.id) {
                selectedNoteIDs = [nearest.id]
            }
        }
        guard let editID = velocityEditID else { return }
        let fraction = max(0, min(1, Double(velocityLaneHeight - y) /
                                     Double(max(1, velocityLaneHeight - 4))))
        let target = max(1, min(127, Int((fraction * 127).rounded())))
        let delta = target - velocityDragStart
        var draft = original
        var modified = false
        for index in draft.clips.indices {
            guard case .midi(var midi) = draft.clips[index].content else { continue }
            for eventIndex in midi.events.indices {
                guard selectedNoteIDs.contains(midi.events[eventIndex].id),
                      case .note(var data) = midi.events[eventIndex].type else { continue }
                // Apply a shared relative shift to preserve chord dynamics.
                let newValue = UInt8(max(1, min(127, Int(data.velocity) + delta)))
                if newValue != data.velocity { modified = true }
                data.velocity = newValue
                midi.events[eventIndex].type = .note(data)
            }
            draft.clips[index].content = .midi(midi)
        }
        _ = editID
        velocityHasChanged = modified
        previewTrack = draft
    }
    
    // MARK: - CC Canvas
    
    private var ccCanvas: some View {
        StudioExpressionLaneCanvas(
            events: ccEvents,
            lane: selectedCCType,
            channel: UInt8(expressionChannel),
            pixelsPerBeat: pixelsPerBeat,
            width: totalWidth,
            height: ccLaneHeight,
            beatsPerBar: StudioMusicalGrid.beatsPerBar(viewModel.transportState.timeSignature),
            playheadBeat: currentPlayheadBeat,
            onDraw: previewExpression,
            onFinish: commitExpression
        )
    }

    // MARK: - Note Editing Gesture
    
    // Find note at a given position
    private func noteAt(x: CGFloat, y: CGFloat) -> MIDIEvent? {
        let clickBeat = x / pixelsPerBeat
        let clickPitch = pitchFromY(y)
        
        for event in noteEvents {
            if case .note(let noteData) = event.type {
                let noteStartBeat = event.beatPosition
                let noteEndBeat = noteStartBeat + noteData.duration
                let notePitch = Int(noteData.pitch)
                
                if clickBeat >= noteStartBeat && clickBeat <= noteEndBeat && clickPitch == notePitch {
                    return event
                }
            }
        }
        return nil
    }
    
    private var noteEditingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let beat = max(0, value.location.x / pixelsPerBeat)
                let pitch = max(0, min(127, pitchFromY(value.location.y)))
                switch currentTool {
                case .pencil:
                    if pencilPreviewStart == nil {
                        pencilPreviewStart = snapBeat(beat)
                        pencilPreviewPitch = pitch
                        pencilPreviewDuration = snapMode.division(for: viewModel.transportState.timeSignature) > 0
                            ? snapMode.division(for: viewModel.transportState.timeSignature) : 0.25
                        viewModel.playNotePreview(pitch: UInt8(pitch))
                    } else if let start = pencilPreviewStart {
                        let grid = snapMode.division(for: viewModel.transportState.timeSignature)
                        pencilPreviewDuration = max(grid > 0 ? grid : 0.25, snapBeat(beat) - start)
                    }

                case .select:
                    isViewFocused = true
                    if draggedNoteID == nil && !isMarqueeSelecting {
                        if let clicked = noteAt(x: value.startLocation.x,
                                                y: value.startLocation.y) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                if !didToggleShiftNote {
                                    if selectedNoteIDs.contains(clicked.id) {
                                        selectedNoteIDs.remove(clicked.id)
                                    } else {
                                        selectedNoteIDs.insert(clicked.id)
                                    }
                                    didToggleShiftNote = true
                                }
                                return
                            }
                            if !selectedNoteIDs.contains(clicked.id) {
                                selectedNoteIDs = [clicked.id]
                            }
                            var mode: NoteDragMode = .move
                            if case .note(let note) = clicked.type {
                                let startX = clicked.beatPosition * pixelsPerBeat
                                let endX = (clicked.beatPosition + note.duration) * pixelsPerBeat
                                let grab = min(7.0, max(2.0, (endX - startX) / 3))
                                if value.startLocation.x <= startX + grab {
                                    mode = .resizeStart
                                } else if value.startLocation.x >= endX - grab {
                                    mode = .resizeEnd
                                }
                            }
                            startNoteDrag(clicked, mode: mode)
                        } else {
                            isMarqueeSelecting = true
                            selectionRect = CGRect(origin: value.startLocation, size: .zero)
                        }
                    }
                    if draggedNoteID != nil {
                        handleNoteDrag(value.translation)
                    } else if isMarqueeSelecting {
                        let origin = CGPoint(x: min(value.startLocation.x, value.location.x),
                                             y: min(value.startLocation.y, value.location.y))
                        selectionRect = CGRect(origin: origin,
                            size: CGSize(width: abs(value.location.x - value.startLocation.x),
                                         height: abs(value.location.y - value.startLocation.y)))
                    }

                case .eraser:
                    if let hovered = noteAt(x: value.location.x, y: value.location.y) {
                        eraserPendingIDs.insert(hovered.id)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                let beat = max(0, value.location.x / pixelsPerBeat)
                let pitch = max(0, min(127, pitchFromY(value.location.y)))
                switch currentTool {
                case .pencil:
                    if let start = pencilPreviewStart, let selectedPitch = pencilPreviewPitch {
                        createNote(at: start, pitch: selectedPitch, duration: pencilPreviewDuration)
                        viewModel.stopNotePreview(pitch: UInt8(selectedPitch))
                    }
                    pencilPreviewStart = nil
                    pencilPreviewPitch = nil
                    pencilPreviewDuration = 0
                case .select:
                    if draggedNoteID != nil {
                        endNoteDrag()
                    } else if isMarqueeSelecting, let rect = selectionRect {
                        selectNotesInRect(rect)
                    }
                    isMarqueeSelecting = false
                    selectionRect = nil
                    didToggleShiftNote = false
                case .eraser:
                    if let hovered = noteAt(x: value.location.x, y: value.location.y) {
                        eraserPendingIDs.insert(hovered.id)
                    }
                    deleteNoteIDs(eraserPendingIDs, description: "Erase MIDI Notes")
                    eraserPendingIDs.removeAll()
                default:
                    break
                }
            }
    }

    // MARK: - Piano Keyboard
    
    private var pianoKeyboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach((visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11).reversed(), id: \.self) { pitch in
                    AdvancedPianoKeyView(
                        pitch: UInt8(pitch),
                        noteHeight: noteHeight,
                        onPress: { viewModel.playNotePreview(pitch: UInt8(pitch)) },
                        onRelease: { viewModel.stopNotePreview(pitch: UInt8(pitch)) }
                    )
                }
            }
        }
    }
    
    // MARK: - Piano Keys Canvas (for synchronized scrolling)
    
    private var pianoKeysCanvas: some View {
        Canvas { context, size in
            let pitchRange = visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11
            
            for (index, pitch) in pitchRange.reversed().enumerated() {
                let y = Double(index) * Double(noteHeight)
                let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
                let isC = pitch % 12 == 0
                
                // Key background (white keys = white, black keys = black)
                let keyRect = CGRect(x: 0, y: y, width: size.width, height: Double(noteHeight))
                
                if isBlackKey {
                    context.fill(Path(keyRect), with: .color(Color.black))
                } else {
                    context.fill(Path(keyRect), with: .color(Color.white.opacity(0.85)))
                }
                
                // Key border
                let borderPath = Path { path in
                    path.move(to: CGPoint(x: 0, y: y + Double(noteHeight)))
                    path.addLine(to: CGPoint(x: size.width, y: y + Double(noteHeight)))
                }
                context.stroke(borderPath, with: .color(Color.gray.opacity(0.5)), lineWidth: 0.5)
                
                // Note name for C notes (black text on white key)
                if isC {
                    let octave = pitch / 12 - 1
                    let noteText = Text("C\(octave)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.black)
                    context.draw(noteText, at: CGPoint(x: size.width - 18, y: y + Double(noteHeight) / 2))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let pitch = pitchFromY(value.location.y)
                    let validPitch = (0...127).contains(pitch) ? pitch : nil
                    guard validPitch != pressedCanvasPitch else { return }
                    if let previous = pressedCanvasPitch {
                        viewModel.stopNotePreview(pitch: UInt8(previous))
                    }
                    pressedCanvasPitch = validPitch
                    if let current = validPitch {
                        viewModel.playNotePreview(pitch: UInt8(current))
                    }
                }
                .onEnded { _ in
                    if let pitch = pressedCanvasPitch {
                        viewModel.stopNotePreview(pitch: UInt8(pitch))
                    }
                    pressedCanvasPitch = nil
                }
        )
    }
    
    
    // MARK: - Helper Functions
    
    private func pitchFromY(_ y: CGFloat) -> Int {
        let index = Int(y / noteHeight)
        return pitchOffset - index
    }
    
    private func snapBeat(_ beat: Double) -> Double {
        if NSEvent.modifierFlags.contains(.command) {
            return beat
        }
        guard snapMode != .off, snapMode.division(for: viewModel.transportState.timeSignature) > 0 else { return beat }
        return round(beat / snapMode.division(for: viewModel.transportState.timeSignature)) * snapMode.division(for: viewModel.transportState.timeSignature)
    }
    
    private func selectNote(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift) {
            if selectedNoteIDs.contains(id) {
                selectedNoteIDs.remove(id)
            } else {
                selectedNoteIDs.insert(id)
            }
        } else {
            selectedNoteIDs = [id]
        }
    }
    
    private func selectNotesInRect(_ rect: CGRect) {
        var newSelection: Set<UUID> = NSEvent.modifierFlags.contains(.shift) ? selectedNoteIDs : []

        for event in noteEvents {
            if case .note(let noteData) = event.type {
                let x = event.beatPosition * pixelsPerBeat
                let y = Double(pitchOffset - Int(noteData.pitch)) * Double(noteHeight)
                let width = noteData.duration * pixelsPerBeat
                let noteRect = CGRect(x: x, y: y, width: width, height: Double(noteHeight))

                if rect.intersects(noteRect) {
                    newSelection.insert(event.id)
                }
            }
        }

        selectedNoteIDs = newSelection
    }
    
    // MARK: - Note Operations
    
    /// Move selected notes visually during drag (doesn't commit to model yet)
    private func selectAllNotes() {
        selectedNoteIDs = Set(noteEvents.map(\.id))
    }

    private func copySelectedNotes() {
        copiedNotes = StudioMIDINoteEditing.selectedNotes(in: noteEvents,
                                                           ids: selectedNoteIDs)
        let ids = Set(copiedNotes.map(\.id))
        copiedArticulations = articulationAssignments.filter { ids.contains($0.key) }
    }

    /// Paste notes at the playhead, retaining their channel, velocity and
    /// relative spacing. Create a region if no MIDI region covers the playhead.
    private func pasteNotes() {
        guard !copiedNotes.isEmpty else { return }
        insertNotes(copiedNotes, at: max(0, viewModel.transportState.playheadBeats),
                    description: "Paste MIDI Notes",
                    sourceArticulations: copiedArticulations)
    }

    private func duplicateSelectedNotes() {
        let source = StudioMIDINoteEditing.selectedNotes(in: noteEvents,
                                                         ids: selectedNoteIDs)
        guard !source.isEmpty else { return }
        let end = source.compactMap { event -> Double? in
            guard case .note(let data) = event.type else { return nil }
            return event.beatPosition + data.duration
        }.max() ?? 0
        insertNotes(source, at: max(0, end), description: "Duplicate MIDI Notes",
                    sourceArticulations: articulationAssignments)
    }

    private func insertNotes(_ source: [MIDIEvent], at anchor: Double,
                             description: String,
                             sourceArticulations: [UUID: String] = [:]) {
        guard var track = currentTrack, anchor.isFinite, anchor >= 0 else { return }
        var positioned: [MIDIEvent] = []
        let idMapping = StudioMIDINoteEditing.pasteWithIDMapping(
            source, into: &positioned, at: anchor)
        let insertedIDs = Set(idMapping.values)
        guard !insertedIDs.isEmpty else { return }

        let tempo = viewModel.transportState.tempo.bpm
        let sampleRate = viewModel.project.sampleRate
        let destinationIndex = track.clips.firstIndex { clip in
            guard clip.content.isMIDI else { return false }
            let start = clip.timeRange.start.beats(atTempo: tempo)
            let end = clip.timeRange.end.beats(atTempo: tempo)
            return anchor >= start && anchor <= end
        }
        if let index = destinationIndex,
           case .midi(var midi) = track.clips[index].content {
            let start = track.clips[index].timeRange.start.beats(atTempo: tempo)
            for var note in positioned {
                note.beatPosition -= start
                midi.events.append(note)
            }
            StudioArticulationAssignmentEditing.transfer(
                from: sourceArticulations, idMapping: idMapping, into: &midi)
            let oldLength = track.clips[index].timeRange.duration.beats(atTempo: tempo)
            let neededLength = midi.events.compactMap { event -> Double? in
                guard insertedIDs.contains(event.id),
                      case .note(let data) = event.type else { return nil }
                return event.beatPosition + data.duration
            }.max() ?? 0
            if neededLength > oldLength {
                track.clips[index].timeRange = TimeRange(
                    start: track.clips[index].timeRange.start,
                    duration: TimePosition(beats: neededLength, tempo: tempo,
                                           sampleRate: sampleRate))
            }
            track.clips[index].content = .midi(midi)
        } else {
            let required = positioned.compactMap { event -> Double? in
                guard case .note(let data) = event.type else { return nil }
                return event.beatPosition + data.duration - anchor
            }.max() ?? 1
            let bar = StudioMusicalGrid.beatsPerBar(viewModel.transportState.timeSignature)
            let length = max(bar, ceil((required + 0.001) / bar) * bar)
            let start = TimePosition(beats: anchor, tempo: tempo, sampleRate: sampleRate)
            let duration = TimePosition(beats: length, tempo: tempo, sampleRate: sampleRate)
            for index in positioned.indices {
                positioned[index].beatPosition -= anchor
            }
            var midi = MIDIClipData(events: positioned)
            StudioArticulationAssignmentEditing.transfer(
                from: sourceArticulations, idMapping: idMapping, into: &midi)
            let region = Clip(name: "MIDI", timeRange: TimeRange(start: start,
                              duration: duration), content: .midi(midi))
            track.clips.append(region)
        }

        viewModel.updateTrack(track, description: description)
        selectedNoteIDs = insertedIDs
    }

    private func createNote(at beat: Double, pitch: Int, duration: Double, velocity: UInt8 = 100) {
        guard pitch >= 0, pitch <= 127, beat.isFinite, beat >= 0 else { return }
        let note = MIDIEvent.note(at: beat, pitch: UInt8(pitch), velocity: velocity,
                                  duration: max(0.0625, duration))
        insertNotes([note], at: beat, description: "Add MIDI Note")
    }

    private func deleteNoteIDs(_ ids: Set<UUID>, description: String) {
        guard !ids.isEmpty, var track = currentTrack else { return }
        var changed = false
        for index in track.clips.indices {
            guard case .midi(var midi) = track.clips[index].content else { continue }
            let edited = StudioMIDINoteEditing.deletingSelected(in: midi.events, ids: ids)
            if edited.count != midi.events.count {
                midi.events = edited
                track.clips[index].content = .midi(midi)
                changed = true
            }
        }
        guard changed else { return }
        viewModel.updateTrack(track, description: description)
        selectedNoteIDs.subtract(ids)
    }

    private func deleteSelectedNotes() {
        deleteNoteIDs(selectedNoteIDs, description: "Delete MIDI Notes")
    }

    private func updateNoteVelocity(_ id: UUID, velocity: UInt8) {
        guard var track = currentTrack else { return }
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                if let eventIndex = midiData.events.firstIndex(where: { $0.id == id }) {
                    if case .note(var noteData) = midiData.events[eventIndex].type {
                        noteData.velocity = velocity
                        midiData.events[eventIndex].type = .note(noteData)
                        track.clips[clipIndex].content = .midi(midiData)
                        viewModel.updateTrack(track, description: "Edit Velocity")
                        return
                    }
                }
            }
        }
    }
    
    // MARK: - Note Dragging
    
    private func startNoteDrag(_ event: MIDIEvent, mode: NoteDragMode) {
        draggedNoteID = event.id
        dragMode = mode
        dragStartBeat = event.beatPosition
        if case .note(let data) = event.type {
            dragStartPitch = Int(data.pitch)
            dragStartDuration = data.duration
        }
        if !selectedNoteIDs.contains(event.id) {
            selectedNoteIDs = [event.id]
        }
        dragStartPositions.removeAll()
        for selected in noteEvents where selectedNoteIDs.contains(selected.id) {
            if case .note(let data) = selected.type {
                dragStartPositions[selected.id] = (
                    beat: selected.beatPosition, pitch: Int(data.pitch),
                    duration: data.duration
                )
            }
        }
        isCopyingNotes = NSEvent.modifierFlags.contains(.option) && mode == .move
        dragHasMaterialChange = false
        previewTrack = nil
    }

    private func handleNoteDrag(_ delta: CGSize) {
        guard let draggedID = draggedNoteID,
              let original = currentTrack else { return }
        let beatDelta = Double(delta.width) / pixelsPerBeat
        let pitchDelta = Int((-delta.height / noteHeight).rounded())
        let division = snapMode.division(for: viewModel.transportState.timeSignature)
        let bypass = NSEvent.modifierFlags.contains(.command)
        var draft = original
        let tempo = viewModel.transportState.tempo.bpm

        // Compute the snapped displacement for the entire selection once.
        // Notes in different regions therefore retain their relative timing.
        let starts = dragStartPositions.values.map(\.beat)
        let firstBeat = starts.min() ?? dragStartBeat
        // A vertical-only drag must not quantize an unsnapped note start.
        let newAnchor = abs(beatDelta) < 0.000001 ? firstBeat :
            StudioMusicalGrid.snap(firstBeat + beatDelta,
                                   division: division, bypass: bypass)
        // A multi-region selection shares one delta, limited by the earliest
        // selected note's position relative to its own MIDI region.
        let earliestLocal = original.clips.compactMap { clip -> Double? in
            guard case .midi(let midi) = clip.content else { return nil }
            return midi.events.compactMap { event -> Double? in
                guard selectedNoteIDs.contains(event.id), case .note = event.type else {
                    return nil
                }
                return event.beatPosition
            }.min()
        }.min() ?? 0
        let sharedDelta = max(newAnchor - firstBeat, -max(0, earliestLocal))
        let pitches = dragStartPositions.values.map(\.pitch)
        let safePitchDelta = max(-(pitches.min() ?? 0),
                                 min(127 - (pitches.max() ?? 127), pitchDelta))

        for index in draft.clips.indices {
            guard case .midi(let source) = original.clips[index].content else { continue }
            let clipStart = original.clips[index].timeRange.start.beats(atTempo: tempo)
            let changedEvents: [MIDIEvent]
            switch dragMode {
            case .move:
                changedEvents = StudioMIDINoteEditing.moving(
                    source.events, selectedIDs: selectedNoteIDs,
                    beatDelta: sharedDelta, pitchDelta: safePitchDelta,
                    division: 0, bypassSnap: true, clipStartBeat: clipStart)
            case .resizeStart:
                changedEvents = StudioMIDINoteEditing.resizing(
                    source.events, noteID: draggedID, edge: .start,
                    beatDelta: beatDelta, division: division, bypassSnap: bypass,
                    minimumDuration: max(0.0625, division), clipStartBeat: clipStart)
            case .resizeEnd:
                changedEvents = StudioMIDINoteEditing.resizing(
                    source.events, noteID: draggedID, edge: .end,
                    beatDelta: beatDelta, division: division, bypassSnap: bypass,
                    minimumDuration: max(0.0625, division), clipStartBeat: clipStart)
            case .none:
                return
            }
            var edited = source
            edited.events = changedEvents
            draft.clips[index].content = .midi(edited)
        }

        dragHasMaterialChange = zip(original.clips, draft.clips).contains { oldClip, newClip in
            guard case .midi(let before) = oldClip.content,
                  case .midi(let after) = newClip.content else { return false }
            return zip(before.events, after.events).contains { first, second in
                guard selectedNoteIDs.contains(first.id),
                      case .note(let oldNote) = first.type,
                      case .note(let newNote) = second.type else { return false }
                return first.beatPosition != second.beatPosition ||
                       oldNote.pitch != newNote.pitch ||
                       oldNote.duration != newNote.duration
            }
        }
        previewTrack = draft

        if dragMode == .move, safePitchDelta != 0 {
            let newPitch = max(0, min(127, dragStartPitch + safePitchDelta))
            if newPitch != lastAuditionedPitch {
                if let previous = lastAuditionedPitch {
                    viewModel.stopNotePreview(pitch: UInt8(previous))
                }
                viewModel.playNotePreview(pitch: UInt8(newPitch))
                lastAuditionedPitch = newPitch
            }
        } else if let previous = lastAuditionedPitch {
            viewModel.stopNotePreview(pitch: UInt8(previous))
            lastAuditionedPitch = nil
        }
    }

    private func endNoteDrag() {
        defer {
            if let last = lastAuditionedPitch {
                viewModel.stopNotePreview(pitch: UInt8(last))
            }
            previewTrack = nil
            draggedNoteID = nil
            dragMode = .none
            dragStartPositions.removeAll()
            lastAuditionedPitch = nil
            isCopyingNotes = false
            dragHasMaterialChange = false
        }
        guard dragHasMaterialChange,
              let original = currentTrack, let draft = previewTrack else { return }

        if isCopyingNotes && dragMode == .move {
            var copied = original
            var newIDs = Set<UUID>()
            for index in copied.clips.indices {
                guard case .midi(var source) = copied.clips[index].content,
                      case .midi(let moved) = draft.clips[index].content else { continue }
                var mapping: [UUID: UUID] = [:]
                let sourceArticulations =
                    StudioArticulationAssignmentEditing.byNoteID(in: source)
                for event in moved.events where selectedNoteIDs.contains(event.id) {
                    guard case .note = event.type else { continue }
                    var duplicate = event
                    duplicate.id = UUID()
                    source.events.append(duplicate)
                    newIDs.insert(duplicate.id)
                    mapping[event.id] = duplicate.id
                }
                StudioArticulationAssignmentEditing.transfer(
                    from: sourceArticulations, idMapping: mapping, into: &source)
                copied.clips[index].content = .midi(source)
            }
            guard !newIDs.isEmpty else { return }
            viewModel.updateTrack(extendingEditedRegions(copied, noteIDs: newIDs),
                                  description: "Copy MIDI Notes")
            selectedNoteIDs = newIDs
        } else {
            viewModel.updateTrack(extendingEditedRegions(draft, noteIDs: selectedNoteIDs),
                                  description: "Edit MIDI Notes")
        }
    }

    /// Make notes moved beyond a MIDI region's right boundary playable without
    /// revealing unrelated events that were deliberately hidden by trimming.
    private func extendingEditedRegions(_ track: Track, noteIDs: Set<UUID>) -> Track {
        guard !noteIDs.isEmpty else { return track }
        var adjusted = track
        let tempo = viewModel.transportState.tempo.bpm
        let sampleRate = viewModel.project.sampleRate
        for index in adjusted.clips.indices {
            guard case .midi(let midi) = adjusted.clips[index].content else { continue }
            let end = midi.events.compactMap { event -> Double? in
                guard noteIDs.contains(event.id),
                      case .note(let data) = event.type else { return nil }
                return event.beatPosition + data.duration
            }.max() ?? 0
            let duration = adjusted.clips[index].timeRange.duration.beats(atTempo: tempo)
            guard end > duration else { continue }
            adjusted.clips[index].timeRange = TimeRange(
                start: adjusted.clips[index].timeRange.start,
                duration: TimePosition(beats: end, tempo: tempo, sampleRate: sampleRate)
            )
        }
        return adjusted
    }

    // MARK: - Musical Articulation Assignments

    private func assignArticulation(_ articulationID: String?, to noteIDs: Set<UUID>) {
        guard var track = currentTrack, !noteIDs.isEmpty else { return }
        if let articulationID,
           track.articulationMap?.definition(for: articulationID) == nil { return }

        var changed = false
        for index in track.clips.indices {
            guard case .midi(var midi) = track.clips[index].content else { continue }
            if StudioArticulationAssignmentEditing.assign(articulationID,
                                                          to: noteIDs, in: &midi) {
                track.clips[index].content = .midi(midi)
                changed = true
            }
        }
        guard changed else { return }
        viewModel.updateTrack(track, description: "Assign Musical Articulation")
    }

    // MARK: - Orchestral MIDI Expression

    private func previewExpression(_ point: StudioMIDIExpressionPoint) {
        guard let original = currentTrack, point.beat.isFinite,
              point.beat >= 0 else { return }
        let tempo = viewModel.transportState.tempo.bpm
        let sampleRate = viewModel.project.sampleRate
        let bar = StudioMusicalGrid.beatsPerBar(viewModel.transportState.timeSignature)

        if expressionTargetClipID == nil {
            if let clip = original.clips.first(where: { clip in
                guard clip.content.isMIDI else { return false }
                let start = clip.timeRange.start.beats(atTempo: tempo)
                let end = clip.timeRange.end.beats(atTempo: tempo)
                return point.beat >= start && point.beat < end
            }) {
                expressionTargetClipID = clip.id
            } else {
                // Drawing expression on an empty lane creates one MIDI region,
                // together with its controller events in a single undo action.
                let startBeat = floor(point.beat / bar) * bar
                let region = Clip(name: "MIDI Expression",
                    timeRange: TimeRange(
                        start: TimePosition(beats: startBeat, tempo: tempo,
                                            sampleRate: sampleRate),
                        duration: TimePosition(beats: bar, tempo: tempo,
                                                sampleRate: sampleRate)),
                    content: .midi(MIDIClipData()))
                expressionNewClip = region
                expressionTargetClipID = region.id
            }
        }

        var draft = original
        if let newClip = expressionNewClip {
            draft.clips.append(newClip)
        }
        guard let targetID = expressionTargetClipID,
              let index = draft.clips.firstIndex(where: { $0.id == targetID }),
              case .midi(let originalData) = draft.clips[index].content else { return }
        let clip = draft.clips[index]
        let start = clip.timeRange.start.beats(atTempo: tempo)
        let end = clip.timeRange.end.beats(atTempo: tempo)
        guard point.beat >= start, point.beat < end else { return }

        let division = snapMode.division(for: viewModel.transportState.timeSignature)
        let step = division > 0 ? division : 0.125
        if let last = expressionStroke.last,
           Int((last.beat / step).rounded()) == Int((point.beat / step).rounded()) {
            expressionStroke[expressionStroke.count - 1] = point
        } else if expressionStroke.count < 4096 {
            expressionStroke.append(point)
        }

        var edited = originalData
        edited.events = StudioMIDIExpressionEditing.draw(
            events: originalData.events, lane: selectedCCType,
            points: expressionStroke, clipStartBeat: start,
            division: step, channel: UInt8(expressionChannel))
        draft.clips[index].content = .midi(edited)
        previewTrack = draft
    }

    private func commitExpression() {
        defer {
            expressionStroke.removeAll()
            expressionTargetClipID = nil
            expressionNewClip = nil
            previewTrack = nil
        }
        guard !expressionStroke.isEmpty, let draft = previewTrack else { return }
        viewModel.updateTrack(draft, description: "Draw \(selectedCCType.name) MIDI Expression")
    }

    /// Instrument-specific articulation changes are ordinary keyswitch notes;
    /// the user selects the pitch and channel required by the loaded patch.
    private func insertKeyswitch() {
        let beat = max(0, viewModel.transportState.playheadBeats)
        let trigger = MIDIEvent.note(at: beat, pitch: UInt8(keyswitchPitch),
                                     velocity: 100, duration: 0.125,
                                     channel: UInt8(expressionChannel))
        insertNotes([trigger], at: beat, description: "Insert Articulation Keyswitch")
    }

    // MARK: - Quantize & Offset
    
    private func quantizeSelectedNotes(to grid: QuantizeGrid) {
        guard var track = currentTrack else { return }
        guard !selectedNoteIDs.isEmpty else { return }
        
        let gridDivision = grid.division
        guard gridDivision > 0 else { return }
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                
                for i in 0..<midiData.events.count {
                    if selectedNoteIDs.contains(midiData.events[i].id) {
                        let absoluteBeat = clipStartBeat + midiData.events[i].beatPosition
                        let quantizedAbsolute = round(absoluteBeat / gridDivision) * gridDivision
                        midiData.events[i].beatPosition = quantizedAbsolute - clipStartBeat
                    }
                }
                
                track.clips[clipIndex].content = .midi(midiData)
            }
        }
        
        viewModel.updateTrack(track, description: "Quantize")
        showQuantizeDialog = false
    }
    
    private func applyOffset(milliseconds: Double) {
        guard var track = currentTrack else { return }
        guard !selectedNoteIDs.isEmpty else { return }

        let tempo = viewModel.transportState.tempo.bpm
        let beatOffset = (milliseconds / 1000.0) * (tempo / 60.0)

        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                for i in 0..<midiData.events.count {
                    if selectedNoteIDs.contains(midiData.events[i].id) {
                        midiData.events[i].beatPosition = max(0, midiData.events[i].beatPosition + beatOffset)
                    }
                }
                track.clips[clipIndex].content = .midi(midiData)
            }
        }

        viewModel.updateTrack(track, description: "Offset Notes")
    }
    
    // MARK: - Zoom Functions
    
    private func zoomHorizontal(zoomIn: Bool) {
        let zoomFactor = 1.25
        let minPixelsPerBeat: Double = 10
        let maxPixelsPerBeat: Double = 120  // Limited to prevent alignment issues
        
        if zoomIn {
            pixelsPerBeat = min(maxPixelsPerBeat, pixelsPerBeat * zoomFactor)
        } else {
            pixelsPerBeat = max(minPixelsPerBeat, pixelsPerBeat / zoomFactor)
        }
    }
    
    private func zoomVertical(zoomIn: Bool) {
        let zoomFactor: CGFloat = 1.25
        let minNoteHeight: CGFloat = 6
        let maxNoteHeight: CGFloat = 40
        
        if zoomIn {
            noteHeight = min(maxNoteHeight, noteHeight * zoomFactor)
        } else {
            noteHeight = max(minNoteHeight, noteHeight / zoomFactor)
        }
    }
}

// MARK: - Track Note View

struct TrackNoteView: View {
    let event: MIDIEvent
    let noteData: NoteData
    let isSelected: Bool
    let pixelsPerBeat: Double
    let noteHeight: CGFloat
    let pitchOffset: Int
    let noteColor: Color
    let onSelect: () -> Void
    let onDragStart: (NoteDragMode) -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    @State private var isDragging: Bool = false
    @State private var currentDragMode: NoteDragMode = .none
    @State private var hoverPosition: CGFloat = 0
    @State private var isHovering: Bool = false

    private let resizeHandleWidth: CGFloat = 6

    var body: some View {
        let x = CGFloat(event.beatPosition) * pixelsPerBeat
        let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
        let width = max(4, CGFloat(noteData.duration) * pixelsPerBeat)

        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(noteColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(Double(noteData.velocity) / 127 * 0.3))

            if isSelected {
                HStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: resizeHandleWidth)
                    Spacer()
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: resizeHandleWidth)
                }
            }
        }
        .frame(width: width, height: noteHeight - 2)
        .offset(x: x, y: y + 1)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isHovering = true
                hoverPosition = location.x
                updateCursor(at: location.x, width: width)
            case .ended:
                isHovering = false
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        let localX = value.startLocation.x
                        if localX < resizeHandleWidth && isSelected {
                            currentDragMode = .resizeStart
                        } else if localX > width - resizeHandleWidth && isSelected {
                            currentDragMode = .resizeEnd
                        } else {
                            currentDragMode = .move
                        }
                        onDragStart(currentDragMode)
                    }
                    onDrag(value.translation)
                }
                .onEnded { _ in
                    isDragging = false
                    currentDragMode = .none
                    onDragEnd()
                    if isHovering {
                        updateCursor(at: hoverPosition, width: width)
                    }
                }
        )
        .onTapGesture {
            onSelect()
        }
    }
    
    private func updateCursor(at localX: CGFloat, width: CGFloat) {
        if isSelected {
            if localX < resizeHandleWidth {
                NSCursor.resizeLeftRight.set()
            } else if localX > width - resizeHandleWidth {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }
}
