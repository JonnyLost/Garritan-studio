import SwiftUI
import DAWCore

// MARK: - MIDI Editor Tool

public enum MIDIEditorTool: String, CaseIterable {
    case select = "Select"
    case pencil = "Pencil"
    case eraser = "Eraser"
    case velocity = "Velocity"
    case split = "Split"
    case glue = "Glue"
    case mute = "Mute"
    
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .velocity: return "chart.bar"
        case .split: return "scissors"
        case .glue: return "link"
        case .mute: return "speaker.slash"
        }
    }
    
    var shortcutKey: String {
        switch self {
        case .select: return "A"
        case .pencil: return "P"
        case .eraser: return "E"
        case .velocity: return "V"
        case .split: return "S"
        case .glue: return "G"
        case .mute: return "M"
        }
    }
    
    var cursor: NSCursor {
        switch self {
        case .select: return .arrow
        case .pencil: return .crosshair
        case .eraser: return .disappearingItem
        case .velocity: return .resizeUpDown
        case .split: return .crosshair
        case .glue: return .pointingHand
        case .mute: return .pointingHand
        }
    }
}

// MARK: - Snap Mode

public enum SnapMode: String, CaseIterable {
    case off = "Off"
    case bar = "Bar"
    case beat = "Beat"
    case eighth = "1/8"
    case sixteenth = "1/16"
    case thirtysecond = "1/32"
    case triplet = "Triplet"
    
    var division: Double {
        switch self {
        case .off: return 0
        case .bar: return 4.0
        case .beat: return 1.0
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        case .thirtysecond: return 0.125
        case .triplet: return 1.0/3.0
        }
    }

    func division(for timeSignature: TimeSignature) -> Double {
        self == .bar ? StudioMusicalGrid.beatsPerBar(timeSignature) : division
    }
}

// MARK: - CC Type

public enum CCType: Int, CaseIterable, Identifiable {
    case modulation = 1
    case breath = 2
    case foot = 4
    case volume = 7
    case blend1 = 30
    case blend2 = 31
    case blend3 = 32
    case pan = 10
    case expression = 11
    case sustain = 64
    case portamento = 65
    case sostenuto = 66
    case soft = 67
    case legato = 68
    case autoLegato = 102
    case expressionMode = 104
    case resonance = 71
    case release = 72
    case attack = 73
    case cutoff = 74
    case decay = 75
    case pitchBend = 128 // Special case
    
    public var id: Int { rawValue }
    
    var name: String {
        switch self {
        case .modulation: return "CC1 Dynamics"
        case .breath: return "CC2 Breath"
        case .foot: return "CC4 Foot"
        case .volume: return "CC7 Volume"
        case .blend1: return "CC30 IO Blend 1"
        case .blend2: return "CC31 IO Blend 2"
        case .blend3: return "CC32 IO Blend 3"
        case .pan: return "CC10 Pan"
        case .expression: return "CC11 Expression"
        case .sustain: return "CC64 Sustain"
        case .portamento: return "Portamento"
        case .sostenuto: return "Sostenuto"
        case .soft: return "Soft Pedal"
        case .legato: return "CC68 Legato"
        case .autoLegato: return "CC102 GPO Auto-Legato"
        case .expressionMode: return "CC104 IO GM/GPO Mode"
        case .resonance: return "Resonance"
        case .release: return "Release"
        case .attack: return "Attack"
        case .cutoff: return "Cutoff"
        case .decay: return "Decay"
        case .pitchBend: return "Pitch Bend (14-bit)"
        }
    }
}

// MARK: - Advanced Piano Roll View

public struct AdvancedPianoRollView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let clipID: ClipID
    
    // Editor state
    @State private var currentTool: MIDIEditorTool = .select
    @State private var snapMode: SnapMode = .sixteenth
    @State private var showVelocityLane: Bool = true
    @State private var showCCLane: Bool = false
    @State private var showArticulationLane = false
    @State private var showArticulationMapEditor = false
    @State private var selectedCCType: CCType = .modulation
    @State private var expressionDrawMode: StudioExpressionDrawMode = .pencil
    @State private var expressionChannel = 0
    @State private var expressionStroke: [StudioMIDIExpressionPoint] = []
    @State private var keyswitchPitch = 24
    @State private var showKeyswitchControls = false
    
    // Selection state
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var selectionRect: CGRect? = nil
    @State private var isMarqueeSelecting: Bool = false
    
    // Pencil tool preview state
    @State private var pencilPreviewStart: Double? = nil  // Start beat (absolute)
    @State private var pencilPreviewPitch: Int? = nil
    @State private var pencilPreviewDuration: Double = 0

    // Editing state
    @State private var draggedNoteID: UUID? = nil
    // Drag previews never modify the project; one undoable change is committed
    // only when the gesture completes.
    @State private var previewMIDI: MIDIClipData? = nil
    @State private var dragHasMaterialChange = false
    @State private var dragMode: NoteDragMode = .none
    @State private var dragStartBeat: Double = 0
    @State private var dragStartPitch: Int = 0
    @State private var dragStartDuration: Double = 0
    
    // Multi-select drag state - stores initial positions of all selected notes
    @State private var dragStartPositions: [UUID: (beat: Double, pitch: Int, duration: Double)] = [:]
    
    // Note audition during drag
    @State private var lastAuditionedPitch: Int? = nil
    
    // Modifier key states for drag behavior
    @State private var isCommandHeld: Bool = false
    @State private var isOptionHeld: Bool = false
    @State private var isCopyingNotes: Bool = false  // True when Option+drag should copy
    
    // Quantize dialog
    @State private var showQuantizeDialog: Bool = false
    @State private var showOffsetDialog: Bool = false

    // View state
    @State private var pixelsPerBeat: Double = 60
    @State private var noteHeight: CGFloat = 14
    @State private var visibleOctaveRange: ClosedRange<Int> = 2...7
    
    // Copied notes for paste
    @State private var copiedNotes: [MIDIEvent] = []
    @State private var copiedArticulations: [UUID: String] = [:]
    
    // Playhead position (updated in real-time)
    @State private var currentPlayheadBeat: Double = 0
    
    // Track color for notes
    private var trackColor: Color {
        // Find the track that contains this clip
        if let track = viewModel.project.tracks.first(where: { $0.clips.contains(where: { $0.id == clipID }) }) {
            return Color(hex: track.color.hex) ?? .accentColor
        }
        return .accentColor
    }
    
    private let pianoKeyWidth: CGFloat = 60
    private let velocityLaneHeight: CGFloat = 80
    private let ccLaneHeight: CGFloat = 80
    private let articulationLaneHeight: CGFloat = 42
    
    public init(viewModel: ProjectViewModel, clipID: ClipID) {
        self.viewModel = viewModel
        self.clipID = clipID
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
            
            Divider()
            
            // Main content with unified horizontal scroll
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Left side: Fixed labels column
                    VStack(spacing: 0) {
                        // Empty space for bar ruler alignment
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 24)
                        
                        Divider()
                        
                        // Piano keyboard (scrolls vertically with notes)
                        pianoKeyboard
                            .frame(width: pianoKeyWidth)
                        
                        // Velocity label
                        if showVelocityLane {
                            Divider()
                            Text("Vel")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: velocityLaneHeight)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                        
                        // CC label
                        if showCCLane {
                            Divider()
                            Text(selectedCCType.name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: ccLaneHeight)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                        if showArticulationLane {
                            Divider()
                            Text("Art")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: articulationLaneHeight)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .frame(width: pianoKeyWidth)
                    
                    Divider()
                    
                    // Right side: Unified horizontal scroll for all content
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            // Bar ruler at top
                            barRulerContent
                                .frame(width: totalWidth, height: 24)
                                .background(Color(nsColor: .windowBackgroundColor))
                            
                            Divider()
                            
                            // Note editing area (with vertical scroll)
                            noteEditingArea(geometry: geometry)
                            
                            // Velocity lane
                            if showVelocityLane {
                                Divider()
                                velocityLaneContent
                                    .frame(width: totalWidth, height: velocityLaneHeight)
                            }
                            
                            // CC lane
                            if showCCLane {
                                Divider()
                                ccLaneContent
                                    .frame(width: totalWidth, height: ccLaneHeight)
                            }
                            if showArticulationLane {
                                Divider()
                                StudioArticulationLane(
                                    notes: noteEvents.map { event in
                                        var absolute = event
                                        absolute.beatPosition += clipStartBeat
                                        return absolute
                                    },
                                    assignments: articulationAssignments,
                                    map: currentArticulationMap,
                                    pixelsPerBeat: pixelsPerBeat,
                                    width: totalWidth,
                                    height: articulationLaneHeight,
                                    onAssign: { noteID, articulationID in
                                        assignArticulation(articulationID, to: [noteID])
                                    }
                                )
                                .frame(width: totalWidth, height: articulationLaneHeight)
                            }
                        }
                        .frame(width: totalWidth)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .onKeyPress { keyPress in
            if keyPress.modifiers.contains(.command) {
                switch keyPress.characters.lowercased() {
                case "a": selectAll(); return .handled
                case "c": copySelected(); return .handled
                case "x": copySelected(); deleteSelected(); return .handled
                case "v": paste(); return .handled
                case "d": duplicateSelected(); return .handled
                default: return .ignored
                }
            }
            // Delete, Escape, and precision MIDI note nudging mirror the
            // track piano roll. Command is reserved for editing shortcuts.
            let isDeleteKey = keyPress.key == .delete ||
                              keyPress.key == .deleteForward ||
                              keyPress.characters == "\u{7F}" ||
                              keyPress.characters == "\u{08}"
            if isDeleteKey, !selectedNoteIDs.isEmpty {
                deleteSelected()
                return .handled
            }
            if keyPress.key == .escape {
                selectedNoteIDs.removeAll()
                return .handled
            }
            if !keyPress.modifiers.contains(.command) &&
               !keyPress.modifiers.contains(.control) &&
               !keyPress.modifiers.contains(.option) {
                let larger = keyPress.modifiers.contains(.shift)
                let beatStep = snapMode.division(
                    for: viewModel.transportState.timeSignature)
                let step = beatStep > 0 ? beatStep : 0.125
                let horizontal = larger
                    ? StudioMusicalGrid.beatsPerBar(viewModel.transportState.timeSignature)
                    : step
                switch keyPress.key {
                case .leftArrow:
                    nudgeSelectedNotes(beats: -horizontal)
                    return selectedNoteIDs.isEmpty ? .ignored : .handled
                case .rightArrow:
                    nudgeSelectedNotes(beats: horizontal)
                    return selectedNoteIDs.isEmpty ? .ignored : .handled
                case .upArrow:
                    nudgeSelectedNotes(semitones: larger ? 12 : 1)
                    return selectedNoteIDs.isEmpty ? .ignored : .handled
                case .downArrow:
                    nudgeSelectedNotes(semitones: larger ? -12 : -1)
                    return selectedNoteIDs.isEmpty ? .ignored : .handled
                default:
                    break
                }
            }
            // Controller shape keys must not intercept Command shortcuts
            // or the system's Option/Control combinations.
            if showCCLane &&
               !keyPress.modifiers.contains(.command) &&
               !keyPress.modifiers.contains(.option) &&
               !keyPress.modifiers.contains(.control) {
                switch keyPress.characters.lowercased() {
                case "1": expressionDrawMode = .pencil; return .handled
                case "2": expressionDrawMode = .line; return .handled
                case "3": expressionDrawMode = .curve; return .handled
                case "4": expressionDrawMode = .erase; return .handled
                default: break
                }
            }
            // Tool shortcuts (when no modifier keys are held)
            switch keyPress.characters.lowercased() {
            case "a":
                currentTool = .select
                return .handled
            case "p":
                currentTool = .pencil
                return .handled
            case "e":
                currentTool = .eraser
                return .handled
            case "v":
                currentTool = .velocity
                return .handled
            case "q":
                // Quantize shortcut - only if notes are selected
                if !selectedNoteIDs.isEmpty {
                    showQuantizeDialog = true
                }
                return .handled
            default:
                return .ignored
            }
        }
        .onAppear {
            setupInitialView()
            currentPlayheadBeat = viewModel.transportState.smoothPlayheadBeats
        }
        .onReceive(viewModel.transportState.$smoothPlayheadBeats) { beats in
            currentPlayheadBeat = beats
        }
        .sheet(isPresented: $showQuantizeDialog) {
            QuantizeDialogView(
                noteCount: selectedNoteIDs.count,
                onQuantize: { grid in
                    quantizeSelectedNotes(to: grid)
                },
                onCancel: {
                    showQuantizeDialog = false
                }
            )
        }
        .sheet(isPresented: $showOffsetDialog) {
            OffsetDialogView(
                noteCount: selectedNoteIDs.count,
                tempo: viewModel.transportState.tempo.bpm,
                onApply: { milliseconds in
                    applyOffset(milliseconds: milliseconds)
                    showOffsetDialog = false
                },
                onCancel: {
                    showOffsetDialog = false
                }
            )
        }
        .sheet(isPresented: $showArticulationMapEditor) {
            StudioArticulationMapEditor(
                map: currentArticulationMap,
                garritanProgramID: viewModel.selectedTrackID.flatMap {
                    viewModel.project.track(withID: $0)?.garritanProgramID
                }
            ) { map in
                guard let trackID = viewModel.selectedTrackID,
                      var track = viewModel.project.track(withID: trackID) else { return }
                track.articulationMap = map
                viewModel.updateTrack(track, description: "Edit Articulation Map")
                showArticulationLane = true
            }
        }
    }
    
    // MARK: - Toolbar
    
    private var editorToolbar: some View {
        HStack(spacing: 12) {
            // Close button
            Button(action: { viewModel.closePianoRoll() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            
            Divider().frame(height: 20)
            
            // Tool selection with keyboard shortcuts
            ForEach([MIDIEditorTool.select, .pencil, .eraser, .velocity], id: \.self) { tool in
                Button(action: { currentTool = tool }) {
                    Image(systemName: tool.icon)
                        .foregroundColor(currentTool == tool ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("\(tool.rawValue) (\(tool.shortcutKey))")
            }
            
            Divider().frame(height: 20)
            
            // Snap mode
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
            
            // Quantize button (text only)
            Button("Quantize") { showQuantizeDialog = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Quantize Selected Notes (Q)")
            
            // Offset button
            Button("Offset") { showOffsetDialog = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Apply timing offset to selected notes")
            
            // Edit actions
            HStack(spacing: 4) {
                Button(action: selectAll) {
                    Image(systemName: "checkmark.square")
                }
                .buttonStyle(.plain)
                .help("Select All (⌘A)")
                
                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Delete (⌫)")
                
                Button(action: copySelected) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Copy (⌘C)")
                
                Button(action: paste) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .disabled(copiedNotes.isEmpty)
                .help("Paste (⌘V)")
                
                Button(action: duplicateSelected) {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Duplicate (⌘D)")
            }
            
            Divider().frame(height: 20)
            
            // Lane toggles
            Toggle(isOn: $showVelocityLane) {
                Text("Velocity")
                    .font(.caption)
            }
            .toggleStyle(.button)
            
            Toggle(isOn: $showCCLane) {
                Text("CC")
                    .font(.caption)
            }
            .toggleStyle(.button)
            
            if showCCLane {
                Picker("", selection: $selectedCCType) {
                    ForEach(CCType.allCases) { cc in
                        Text(cc.name).tag(cc)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                Picker("Shape", selection: $expressionDrawMode) {
                    ForEach(StudioExpressionDrawMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 112)
                .help("Expression edit mode: 1 Pencil · 2 Line · 3 Curve · 4 Erase")
            }

            Picker("Ch", selection: $expressionChannel) {
                ForEach(0..<16, id: \.self) { channel in
                    Text("\(channel + 1)").tag(channel)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 75)
            .help("MIDI channel for expression drawing and keyswitch insertion")

            Toggle(isOn: $showArticulationLane) {
                Text("Art")
            }
            .toggleStyle(.button)
            .help("Show musical articulation lane")

            Menu("Articulation") {
                if let map = currentArticulationMap {
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

            Button("Keyswitch") { showKeyswitchControls = true }
                .buttonStyle(.bordered)
                .help("Insert a manual instrument keyswitch note")
                .popover(isPresented: $showKeyswitchControls) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Insert Articulation Keyswitch").font(.headline)
                        Text("Use the MIDI pitch assigned by your instrument. Studio does not assume an articulation map.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("Trigger note: \(NoteData(pitch: UInt8(keyswitchPitch)).noteName) (\(keyswitchPitch))",
                                value: $keyswitchPitch, in: 0...127)
                        Button("Insert at Playhead") {
                            insertKeyswitch()
                            showKeyswitchControls = false
                        }
                        .disabled(currentClip == nil)
                    }
                    .padding()
                    .frame(width: 300)
                }

            Spacer()
            
            // Zoom controls
            HStack(spacing: 4) {
                Button(action: { pixelsPerBeat = max(20, pixelsPerBeat - 10) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                
                Text("\(Int(pixelsPerBeat))px")
                    .font(.caption)
                    .frame(width: 40)
                
                Button(action: { pixelsPerBeat = min(200, pixelsPerBeat + 10) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
            }
            
            // Clip info
            if let clip = currentClip {
                Text(clip.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Piano Keyboard
    
    private var pianoKeyboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(pitchRange.reversed(), id: \.self) { pitch in
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
    
    private var pitchRange: [Int] {
        Array(visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11)
    }
    
    // MARK: - Bar Ruler
    
    /// Bar ruler content for unified scroll (no separate ScrollView)
    private var barRulerContent: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let timeSignature = viewModel.transportState.timeSignature
                let beatsPerBar = StudioMusicalGrid.beatsPerBar(timeSignature)
                let totalBars = Int(ceil(totalWidth / (pixelsPerBeat * beatsPerBar))) + 1

                for bar in 0..<totalBars {
                    let barBeat = Double(bar) * beatsPerBar
                    let x = barBeat * pixelsPerBeat

                    // Bar number (1-indexed for display)
                    let barText = Text("\(bar + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                    context.draw(barText, at: CGPoint(x: x + 8, y: size.height / 2))

                    // Bar line
                    let linePath = Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)

                    // Beat subdivisions
                    for beat in 1..<Int(beatsPerBar) {
                        let beatX = x + Double(beat) * pixelsPerBeat
                        let beatPath = Path { path in
                            path.move(to: CGPoint(x: beatX, y: size.height * 0.6))
                            path.addLine(to: CGPoint(x: beatX, y: size.height))
                        }
                        context.stroke(beatPath, with: .color(Color.gray.opacity(0.3)), lineWidth: 0.5)
                    }
                }
            }
            .frame(width: totalWidth, height: 24)

            // Click area for setting playhead
            Color.clear
                .frame(width: totalWidth, height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            setPlayheadFromClick(at: value.location.x)
                        }
                )
        }
    }
    
    /// Set playhead position from click location in bar ruler
    private func setPlayheadFromClick(at x: CGFloat) {
        let beat = max(0, Double(x) / pixelsPerBeat)
        viewModel.transportState.setPlayheadBeats(beat)
        currentPlayheadBeat = beat
    }

    // MARK: - Note Editing Area
    
    /// Note editing area - only vertical scroll (horizontal handled by parent)
    private func noteEditingArea(geometry: GeometryProxy) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Background grid
                noteGrid(geometry: geometry)

                // Notes (saved in clip)
                notesLayer

                // Live recording notes (real-time display during recording)
                liveRecordingNotesLayer

                // Pencil tool preview
                pencilPreviewLayer

                // Selection marquee
                if let rect = selectionRect, isMarqueeSelecting {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 1)
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.origin.x, y: rect.origin.y)
                }

                // Playhead
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1)
                    .frame(height: totalHeight)
                    .offset(x: playheadX)
            }
            .frame(width: totalWidth, height: totalHeight)
            .contentShape(Rectangle())
            .gesture(editingGesture)
        }
    }
    
    private func noteGrid(geometry: GeometryProxy) -> some View {
        Canvas { context, size in
            let pitchRange = visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11
            
            // Draw horizontal pitch lines
            for (index, pitch) in pitchRange.reversed().enumerated() {
                let y = CGFloat(index) * noteHeight
                let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
                
                // Background color for black keys
                if isBlackKey {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: noteHeight)
                    context.fill(Path(rect), with: .color(Color.black.opacity(0.15)))
                }
                
                // C note highlight
                if pitch % 12 == 0 {
                    let linePath = Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.4)), lineWidth: 1)
                } else {
                    let linePath = Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.15)), lineWidth: 0.5)
                }
            }
            
            // Draw beat subdivisions and true bar starts separately.
            let totalBeats = Int(size.width / pixelsPerBeat) + 1
            let barLength = StudioMusicalGrid.beatsPerBar(viewModel.transportState.timeSignature)
            
            for beat in 0..<totalBeats {
                let x = CGFloat(beat) * pixelsPerBeat
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(linePath, with: .color(Color.gray.opacity(0.2)), lineWidth: 0.5)

                // Subdivision lines
                if snapMode == .sixteenth || snapMode == .thirtysecond {
                    for sub in 1..<4 {
                        let subX = x + (CGFloat(sub) * pixelsPerBeat / 4)
                        let subPath = Path { path in
                            path.move(to: CGPoint(x: subX, y: 0))
                            path.addLine(to: CGPoint(x: subX, y: size.height))
                        }
                        context.stroke(subPath, with: .color(Color.gray.opacity(0.1)), lineWidth: 0.5)
                    }
                }
            }
            for bar in 0...Int(ceil(Double(totalBeats) / barLength)) {
                let x = CGFloat(Double(bar) * barLength) * pixelsPerBeat
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
            }
        }
    }
    
    private var notesLayer: some View {
        ZStack {
            // Ghost notes layer - show original positions while dragging
            ghostNotesLayer
            
            // Actual notes
            ForEach(noteEvents, id: \.id) { event in
                if case .note(let noteData) = event.type {
                    AdvancedNoteView(
                        event: event,
                        noteData: noteData,
                        isSelected: selectedNoteIDs.contains(event.id),
                        pixelsPerBeat: pixelsPerBeat,
                        noteHeight: noteHeight,
                        pitchOffset: pitchOffset,
                        noteColor: trackColor,
                        clipStartBeat: clipStartBeat,  // Add absolute position offset
                        onSelect: { selectNote(event.id) },
                        onDragStart: { mode in startNoteDrag(event, mode: mode) },
                        onDrag: { delta in handleNoteDrag(delta) },
                        onDragEnd: { endNoteDrag() }
                    )
                }
            }
        }
    }
    
    /// Ghost notes showing original position while dragging
    @ViewBuilder
    private var ghostNotesLayer: some View {
        if draggedNoteID != nil && dragMode == .move {
            // Show ghost notes for all notes being dragged
            if !dragStartPositions.isEmpty {
                // Multiple notes - show ghosts for all
                ForEach(Array(dragStartPositions.keys), id: \.self) { noteID in
                    if let startPos = dragStartPositions[noteID] {
                        ghostNoteView(
                            beat: startPos.beat,
                            pitch: startPos.pitch,
                            duration: startPos.duration
                        )
                    }
                }
            } else {
                // Single note
                ghostNoteView(
                    beat: dragStartBeat,
                    pitch: dragStartPitch,
                    duration: dragStartDuration
                )
            }
        }
    }
    
    private func ghostNoteView(beat: Double, pitch: Int, duration: Double) -> some View {
        let absoluteBeat = clipStartBeat + beat
        let x = CGFloat(absoluteBeat) * pixelsPerBeat
        let y = CGFloat(pitchOffset - pitch) * noteHeight
        let width = max(4, CGFloat(duration) * pixelsPerBeat)
        
        return RoundedRectangle(cornerRadius: 2)
            .fill(trackColor.opacity(0.25))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(trackColor.opacity(0.4), lineWidth: 1, antialiased: true)
            )
            .frame(width: width, height: noteHeight - 2)
            .offset(x: x, y: y + 1)
    }
    
    /// Live recording notes - displayed in real-time during MIDI recording
    @ViewBuilder
    private var liveRecordingNotesLayer: some View {
        if viewModel.isRecording {
            let liveEvents = viewModel.midiRecorder.liveRecordedEvents
            let recordingStartBeat = viewModel.midiRecorder.liveRecordingStartBeat
            
            ForEach(liveEvents, id: \.id) { event in
                if case .note(let noteData) = event.type {
                    // Calculate absolute beat position for the live note
                    let absoluteBeat = recordingStartBeat + event.beatPosition
                    let x = CGFloat(absoluteBeat) * pixelsPerBeat
                    let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
                    let width = max(4, CGFloat(noteData.duration) * pixelsPerBeat)
                    
                    // Draw live note with slightly different style (pulsing/brighter)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.green, lineWidth: 1)
                        )
                        .frame(width: width, height: noteHeight - 1)
                        .offset(x: x, y: y)
                }
            }
        }
    }
    
    /// Pencil tool preview - shows note being drawn (matches actual note appearance)
    @ViewBuilder
    private var pencilPreviewLayer: some View {
        if let startBeat = pencilPreviewStart, let pitch = pencilPreviewPitch, pencilPreviewDuration > 0 {
            // Use same positioning as AdvancedNoteView for consistency
            let x = CGFloat(startBeat) * pixelsPerBeat
            let y = CGFloat(pitchOffset - pitch) * noteHeight
            let width = max(4, CGFloat(pencilPreviewDuration) * pixelsPerBeat)
            
            ZStack {
                // Match the actual note appearance
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)
                
                // Velocity indicator (default velocity brightness)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
            }
            .frame(width: width, height: noteHeight - 2)
            .offset(x: x, y: y + 1)
        }
    }
    
    /// The absolute beat where the clip starts on the timeline
    private var clipStartBeat: Double {
        guard let clip = currentClip else { return 0 }
        return clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
    }
    
    // MARK: - Velocity Lane
    
    /// Velocity lane content for unified scroll (no separate ScrollView)
    private var velocityLaneContent: some View {
        ZStack(alignment: .bottomLeading) {
            // Background
            Rectangle()
                .fill(Color.black.opacity(0.2))

            // Velocity bars (use absolute beat position)
            ForEach(noteEvents, id: \.id) { event in
                if case .note(let noteData) = event.type {
                    VelocityBar(
                        beat: clipStartBeat + event.beatPosition,  // Absolute position
                        velocity: noteData.velocity,
                        isSelected: selectedNoteIDs.contains(event.id),
                        pixelsPerBeat: pixelsPerBeat,
                        height: velocityLaneHeight - 4,
                        onVelocityChange: { newVelocity in
                            updateNoteVelocity(event.id, velocity: newVelocity)
                        },
                        onVelocityCommit: {
                            commitNoteVelocity()
                        }
                    )
                }
            }
            
            // Playhead line
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1, height: velocityLaneHeight)
                .offset(x: playheadX)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - CC Lane
    
    /// CC lane content for unified scroll (no separate ScrollView)
    private var ccLaneContent: some View {
        StudioExpressionLaneCanvas(
            events: ccEvents.map { event in
                var absolute = event
                absolute.beatPosition += clipStartBeat
                return absolute
            },
            lane: selectedCCType,
            mode: expressionDrawMode,
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

    // MARK: - Gestures
    
    private var editingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch currentTool {
                case .select:
                    if !isMarqueeSelecting {
                        isMarqueeSelecting = true
                        selectionRect = CGRect(origin: value.startLocation, size: .zero)
                    }
                    let origin = CGPoint(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y)
                    )
                    let size = CGSize(
                        width: abs(value.location.x - value.startLocation.x),
                        height: abs(value.location.y - value.startLocation.y)
                    )
                    selectionRect = CGRect(origin: origin, size: size)
                    
                case .pencil:
                    // Show live preview while drawing
                    let pitch = pitchAt(value.startLocation.y)
                    let clickBeat = snapBeat(value.startLocation.x / pixelsPerBeat)
                    let currentBeat = snapBeat(value.location.x / pixelsPerBeat)
                    let minDuration = snapMode.division(for: viewModel.transportState.timeSignature) > 0 ? snapMode.division(for: viewModel.transportState.timeSignature) : 0.25
                    
                    // Handle dragging left or right - note starts at leftmost position
                    let noteStart = min(clickBeat, currentBeat)
                    let noteEnd = max(clickBeat, currentBeat)
                    let duration = max(minDuration, noteEnd - noteStart)
                    
                    // Set preview state
                    pencilPreviewPitch = pitch
                    pencilPreviewStart = noteStart
                    pencilPreviewDuration = duration

                case .eraser:
                    // Erase notes under cursor
                    let pitch = pitchAt(value.location.y)
                    let beat = value.location.x / pixelsPerBeat
                    eraseNoteAt(beat: beat, pitch: pitch)
                    
                default:
                    break
                }
            }
            .onEnded { value in
                switch currentTool {
                case .select:
                    if let rect = selectionRect {
                        selectNotesInRect(rect)
                    }
                    isMarqueeSelecting = false
                    selectionRect = nil
                    
                case .pencil:
                    // Create note from preview
                    if let startBeat = pencilPreviewStart, let pitch = pencilPreviewPitch {
                        createNote(at: startBeat, pitch: pitch, duration: pencilPreviewDuration)
                    }
                    // Clear preview
                    pencilPreviewStart = nil
                    pencilPreviewPitch = nil
                    pencilPreviewDuration = 0
                    
                default:
                    break
                }
            }
    }
    
    // MARK: - Note Operations
    
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
        var newSelection: Set<UUID> = []
        
        for event in noteEvents {
            if case .note(let noteData) = event.type {
                let noteRect = noteRect(for: event, noteData: noteData)
                if rect.intersects(noteRect) {
                    newSelection.insert(event.id)
                }
            }
        }
        
        if NSEvent.modifierFlags.contains(.shift) {
            selectedNoteIDs.formUnion(newSelection)
        } else {
            selectedNoteIDs = newSelection
        }
    }
    
    private func selectAll() {
        selectedNoteIDs = Set(noteEvents.map { $0.id })
    }
    
    /// One key press is one undoable change. Existing unsnapped offsets
    /// and selected-note articulation IDs are retained automatically.
    private func nudgeSelectedNotes(beats: Double = 0, semitones: Int = 0) {
        guard !selectedNoteIDs.isEmpty, var clip = currentClip,
              case .midi(var midi) = clip.content else { return }
        let edited = StudioMIDINoteEditing.nudging(
            midi.events, selectedIDs: selectedNoteIDs,
            beatDelta: beats, pitchDelta: semitones)
        guard StudioMIDINoteEditing.hasPitchOrTimingChanges(
            before: midi.events, after: edited) else { return }
        midi.events = edited
        clip.content = .midi(midi)
        updateClip(extendingClip(clip, toInclude: selectedNoteIDs),
                   description: "Nudge MIDI Notes")
    }

    private func deleteSelected() {
        guard !selectedNoteIDs.isEmpty,
              var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        let edited = StudioMIDINoteEditing.deletingSelected(in: midiData.events,
                                                            ids: selectedNoteIDs)
        guard edited.count != midiData.events.count else { return }
        midiData.events = edited
        clip.content = .midi(midiData)
        updateClip(clip, description: "Delete MIDI Notes")
        selectedNoteIDs.removeAll()
    }

    private func copySelected() {
        copiedNotes = StudioMIDINoteEditing.selectedNotes(in: noteEvents,
                                                           ids: selectedNoteIDs)
        let selectedIDs = Set(copiedNotes.map(\.id))
        copiedArticulations = articulationAssignments.filter {
            selectedIDs.contains($0.key)
        }
    }

    private func paste() {
        guard !copiedNotes.isEmpty,
              var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        let insertion = max(0, viewModel.transportState.playheadBeats - clipStartBeat)
        let mapping = StudioMIDINoteEditing.pasteWithIDMapping(
            copiedNotes, into: &midiData.events, at: insertion)
        let newIDs = Set(mapping.values)
        guard !newIDs.isEmpty else { return }
        StudioArticulationAssignmentEditing.transfer(
            from: copiedArticulations, idMapping: mapping, into: &midiData)
        clip.content = .midi(midiData)
        updateClip(extendingClip(clip, toInclude: newIDs),
                   description: "Paste MIDI Notes")
        selectedNoteIDs = newIDs
    }

    private func duplicateSelected() {
        guard !selectedNoteIDs.isEmpty,
              var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        let source = StudioMIDINoteEditing.selectedNotes(
            in: midiData.events, ids: selectedNoteIDs)
        let end = source.compactMap { event -> Double? in
            guard case .note(let note) = event.type else { return nil }
            return event.beatPosition + note.duration
        }.max() ?? 0
        let mapping = StudioMIDINoteEditing.pasteWithIDMapping(
            source, into: &midiData.events, at: max(0, end))
        let ids = Set(mapping.values)
        guard !ids.isEmpty else { return }
        StudioArticulationAssignmentEditing.transfer(
            from: articulationAssignments, idMapping: mapping, into: &midiData)
        clip.content = .midi(midiData)
        updateClip(extendingClip(clip, toInclude: ids),
                   description: "Duplicate MIDI Notes")
        selectedNoteIDs = ids
    }

    /// Create a note at an absolute beat position
    private func createNote(at absoluteBeat: Double, pitch: Int, duration: Double, velocity: UInt8 = 100) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }

        // Convert absolute beat to relative beat within the clip
        let relativeBeat = absoluteBeat - clipStartBeat
        
        // Don't create notes before the clip starts
        guard relativeBeat >= 0 else { return }
        
        let newEvent = MIDIEvent.note(
            at: relativeBeat,  // Store as relative to clip start
            pitch: UInt8(pitch),
            velocity: velocity,
            duration: duration
        )

        midiData.events.append(newEvent)
        clip.content = .midi(midiData)

        updateClip(extendingClip(clip, toInclude: [newEvent.id]),
                   description: "Add MIDI Note")
        selectedNoteIDs = [newEvent.id]
        
        // Play preview
        viewModel.playNotePreview(pitch: UInt8(pitch), velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            viewModel.stopNotePreview(pitch: UInt8(pitch))
        }
    }
    
    /// Erase a note at an absolute beat position
    private func eraseNoteAt(beat absoluteBeat: Double, pitch: Int) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }

        // Convert absolute beat to relative for comparison with stored events
        let relativeBeat = absoluteBeat - clipStartBeat

        midiData.events.removeAll { event in
            if case .note(let noteData) = event.type {
                let noteStart = event.beatPosition
                let noteEnd = noteStart + noteData.duration
                return Int(noteData.pitch) == pitch && relativeBeat >= noteStart && relativeBeat <= noteEnd
            }
            return false
        }

        clip.content = .midi(midiData)
        updateClip(clip)
    }
    
    private func updateNoteVelocity(_ id: UUID, velocity: UInt8) {
        guard let clip = currentClip, case .midi(let original) = clip.content else { return }
        var draft = original
        guard let index = draft.events.firstIndex(where: { $0.id == id }),
              case .note(var data) = draft.events[index].type else { return }
        data.velocity = velocity
        draft.events[index].type = .note(data)
        previewMIDI = draft
    }

    /// A velocity-bar drag is one undoable edit, not an undo step per pixel.
    private func commitNoteVelocity() {
        defer { previewMIDI = nil }
        guard let draft = previewMIDI,
              var clip = currentClip,
              case .midi(let original) = clip.content else { return }
        let changed = zip(original.events, draft.events).contains { before, after in
            guard case .note(let a) = before.type,
                  case .note(let b) = after.type else { return false }
            return a.velocity != b.velocity
        }
        guard changed else { return }
        clip.content = .midi(draft)
        updateClip(clip, description: "Edit MIDI Velocity")
    }

    private func quantizeSelectedNotes(to grid: QuantizeGrid) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        guard !selectedNoteIDs.isEmpty else { return }

        let gridDivision = grid.division
        guard gridDivision > 0 else { return }

        for i in 0..<midiData.events.count {
            if selectedNoteIDs.contains(midiData.events[i].id) {
                // Quantize note start position to the selected grid
                let currentBeat = midiData.events[i].beatPosition
                let quantizedBeat = round(currentBeat / gridDivision) * gridDivision
                midiData.events[i].beatPosition = quantizedBeat
            }
        }

        clip.content = .midi(midiData)
        updateClip(clip)
        showQuantizeDialog = false
    }
    
    /// Apply timing offset to selected notes (in milliseconds)
    private func applyOffset(milliseconds: Double) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        guard !selectedNoteIDs.isEmpty else { return }
        
        let tempo = viewModel.transportState.tempo.bpm
        // Convert milliseconds to beats: beats = (ms / 1000) * (tempo / 60)
        let beatOffset = (milliseconds / 1000.0) * (tempo / 60.0)
        
        for i in 0..<midiData.events.count {
            if selectedNoteIDs.contains(midiData.events[i].id) {
                // Apply offset to note position (can go negative for earlier timing)
                let newBeat = midiData.events[i].beatPosition + beatOffset
                // Don't allow notes before 0
                midiData.events[i].beatPosition = max(0, newBeat)
            }
        }
        
        clip.content = .midi(midiData)
        updateClip(clip)
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
        previewMIDI = nil
    }

    private func handleNoteDrag(_ delta: CGSize) {
        guard let id = draggedNoteID,
              let clip = currentClip,
              case .midi(let original) = clip.content else { return }
        let beatDelta = Double(delta.width) / pixelsPerBeat
        let pitchDelta = Int((-delta.height / noteHeight).rounded())
        let division = snapMode.division(for: viewModel.transportState.timeSignature)
        let bypass = NSEvent.modifierFlags.contains(.command)
        let edited: [MIDIEvent]
        switch dragMode {
        case .move:
            edited = StudioMIDINoteEditing.moving(
                original.events, selectedIDs: selectedNoteIDs, beatDelta: beatDelta,
                pitchDelta: pitchDelta, division: division, bypassSnap: bypass,
                clipStartBeat: clipStartBeat)
            let previewPitch = max(0, min(127, dragStartPitch + pitchDelta))
            if previewPitch != lastAuditionedPitch {
                if let previous = lastAuditionedPitch {
                    viewModel.stopNotePreview(pitch: UInt8(previous))
                }
                if pitchDelta != 0 {
                    viewModel.playNotePreview(pitch: UInt8(previewPitch))
                    lastAuditionedPitch = previewPitch
                } else {
                    lastAuditionedPitch = nil
                }
            }
        case .resizeStart:
            edited = StudioMIDINoteEditing.resizing(
                original.events, noteID: id, edge: .start, beatDelta: beatDelta,
                division: division, bypassSnap: bypass,
                minimumDuration: max(0.0625, division))
        case .resizeEnd:
            edited = StudioMIDINoteEditing.resizing(
                original.events, noteID: id, edge: .end, beatDelta: beatDelta,
                division: division, bypassSnap: bypass,
                minimumDuration: max(0.0625, division))
        case .none:
            return
        }
        dragHasMaterialChange = zip(original.events, edited).contains { before, after in
            guard selectedNoteIDs.contains(before.id),
                  case .note(let old) = before.type,
                  case .note(let new) = after.type else { return false }
            return before.beatPosition != after.beatPosition ||
                old.pitch != new.pitch || old.duration != new.duration
        }
        var draft = original
        draft.events = edited
        previewMIDI = draft
    }

    private func endNoteDrag() {
        defer {
            if let last = lastAuditionedPitch {
                viewModel.stopNotePreview(pitch: UInt8(last))
            }
            draggedNoteID = nil
            dragMode = .none
            dragStartPositions.removeAll()
            lastAuditionedPitch = nil
            previewMIDI = nil
            dragHasMaterialChange = false
            isCopyingNotes = false
        }
        guard dragHasMaterialChange, let draft = previewMIDI,
              var clip = currentClip, case .midi(let original) = clip.content else { return }

        if isCopyingNotes && dragMode == .move {
            var copied = original
            var selectedCopies: Set<UUID> = []
            var idMapping: [UUID: UUID] = [:]
            for moved in draft.events where selectedNoteIDs.contains(moved.id) {
                guard case .note = moved.type else { continue }
                var copy = moved
                copy.id = UUID()
                copied.events.append(copy)
                selectedCopies.insert(copy.id)
                idMapping[moved.id] = copy.id
            }
            guard !selectedCopies.isEmpty else { return }
            StudioArticulationAssignmentEditing.transfer(
                from: StudioArticulationAssignmentEditing.byNoteID(in: original),
                idMapping: idMapping, into: &copied)
            clip.content = .midi(copied)
            updateClip(extendingClip(clip, toInclude: selectedCopies),
                       description: "Copy MIDI Notes")
            selectedNoteIDs = selectedCopies
        } else {
            clip.content = .midi(draft)
            updateClip(extendingClip(clip, toInclude: selectedNoteIDs),
                       description: "Edit MIDI Notes")
        }
    }

    // MARK: - Musical Articulation Assignments

    private var currentArticulationMap: StudioArticulationMap? {
        guard let trackID = viewModel.selectedTrackID else { return nil }
        return viewModel.project.track(withID: trackID)?.articulationMap
    }

    private var articulationAssignments: [UUID: String] {
        guard let clip = currentClip, case .midi(let midi) = clip.content else { return [:] }
        return StudioArticulationAssignmentEditing.byNoteID(in: midi)
    }

    private func assignArticulation(_ articulationID: String?, to noteIDs: Set<UUID>) {
        guard var clip = currentClip, case .midi(var midi) = clip.content,
              !noteIDs.isEmpty else { return }
        if let articulationID,
           currentArticulationMap?.definition(for: articulationID) == nil { return }
        guard StudioArticulationAssignmentEditing.assign(articulationID,
                                                         to: noteIDs, in: &midi) else { return }
        clip.content = .midi(midi)
        updateClip(clip, description: "Assign Musical Articulation")
    }

    // MARK: - MIDI Expression / Articulation

    private func previewExpression(_ point: StudioMIDIExpressionPoint) {
        guard let clip = currentClip, case .midi(let original) = clip.content else { return }
        let start = clipStartBeat
        let end = start + clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
        guard point.beat >= start, point.beat < end else { return }
        let division = snapMode.division(for: viewModel.transportState.timeSignature)
        let step = division > 0 ? division : 0.125
        if let last = expressionStroke.last,
           Int((last.beat / step).rounded()) == Int((point.beat / step).rounded()) {
            expressionStroke[expressionStroke.count - 1] = point
        } else if expressionStroke.count < 4096 {
            expressionStroke.append(point)
        }

        var draft = original
        draft.events = StudioMIDIExpressionEditing.draw(
            events: original.events, lane: selectedCCType, points: expressionStroke,
            clipStartBeat: start, division: step, channel: UInt8(expressionChannel),
            mode: expressionDrawMode, clipEndBeat: end)
        previewMIDI = expressionDrawMode == .erase &&
                     draft.events.count == original.events.count ? nil : draft
    }

    private func commitExpression() {
        defer {
            expressionStroke.removeAll()
            previewMIDI = nil
        }
        guard !expressionStroke.isEmpty, let draft = previewMIDI,
              var clip = currentClip else { return }
        clip.content = .midi(draft)
        updateClip(clip, description:
            "\(expressionDrawMode == .erase ? "Erase" : "Draw") \(selectedCCType.name) MIDI Expression")
    }

    /// A keyswitch is a short, ordinary MIDI note. Its meaning is determined
    /// by the selected instrument's keyswitch mapping, not by Studio.
    private func insertKeyswitch() {
        guard var clip = currentClip, case .midi(var midi) = clip.content else { return }
        let beat = viewModel.transportState.playheadBeats - clipStartBeat
        guard beat.isFinite && beat >= 0 else { return }
        let trigger = MIDIEvent.note(
            at: beat, pitch: UInt8(keyswitchPitch), velocity: 100,
            duration: 0.125, channel: UInt8(expressionChannel))
        midi.events.append(trigger)
        clip.content = .midi(midi)
        updateClip(extendingClip(clip, toInclude: [trigger.id]),
                   description: "Insert Articulation Keyswitch")
        selectedNoteIDs = [trigger.id]
    }

    // MARK: - Helpers
    
    private var currentClip: Clip? {
        guard let trackID = viewModel.selectedTrackID,
              let track = viewModel.project.track(withID: trackID) else { return nil }
        return track.clips.first { $0.id == clipID }
    }
    
    private var noteEvents: [MIDIEvent] {
        guard let clip = currentClip, case .midi(let midiData) = clip.content else { return [] }
        let displayed = previewMIDI ?? midiData
        return displayed.events.filter { if case .note = $0.type { return true } else { return false } }
    }
    
    private var ccEvents: [MIDIEvent] {
        guard let clip = currentClip, case .midi(let midiData) = clip.content else { return [] }
        return (previewMIDI ?? midiData).events.filter {
            StudioMIDIExpressionEditing.normalizedValue(
                of: $0, for: selectedCCType, channel: UInt8(expressionChannel)) != nil
        }
    }
    
    private var totalHeight: CGFloat {
        CGFloat((visibleOctaveRange.upperBound - visibleOctaveRange.lowerBound + 1) * 12) * noteHeight
    }
    
    private var totalWidth: CGFloat {
        guard let clip = currentClip else { return 800 }
        // Show from bar 1 (beat 0) to the end of the clip plus some extra space
        let clipEndBeat = clipStartBeat + clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
        // Ensure we show at least 8 bars and extend past the clip
        let minBeats = max(32, clipEndBeat + 8)
        return max(800, CGFloat(minBeats) * pixelsPerBeat)
    }

    private var pitchOffset: Int {
        visibleOctaveRange.upperBound * 12 + 11
    }

    private var playheadX: CGFloat {
        // Use absolute beat position for the playhead
        return CGFloat(currentPlayheadBeat) * pixelsPerBeat
    }
    
    private func pitchAt(_ y: CGFloat) -> Int {
        let index = Int(y / noteHeight)
        return pitchOffset - index
    }
    
    private func snapBeat(_ beat: Double) -> Double {
        // CMD key bypasses grid snapping
        if NSEvent.modifierFlags.contains(.command) {
            return beat
        }
        guard snapMode != .off, snapMode.division(for: viewModel.transportState.timeSignature) > 0 else { return beat }
        return round(beat / snapMode.division(for: viewModel.transportState.timeSignature)) * snapMode.division(for: viewModel.transportState.timeSignature)
    }
    
    private func noteRect(for event: MIDIEvent, noteData: NoteData) -> CGRect {
        // Use absolute beat position for selection rectangles
        let absoluteBeat = clipStartBeat + event.beatPosition
        let x = CGFloat(absoluteBeat) * pixelsPerBeat
        let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
        let width = CGFloat(noteData.duration) * pixelsPerBeat
        return CGRect(x: x, y: y, width: width, height: noteHeight)
    }
    
    /// Grow a MIDI clip only for notes that were actively added or edited.
    /// Existing hidden notes beyond a trimmed boundary stay hidden.
    private func extendingClip(_ clip: Clip, toInclude ids: Set<UUID>) -> Clip {
        guard !ids.isEmpty, case .midi(let midi) = clip.content else { return clip }
        let currentLength = clip.timeRange.duration.beats(
            atTempo: viewModel.transportState.tempo.bpm)
        let latestEnd = midi.events.compactMap { event -> Double? in
            guard ids.contains(event.id), case .note(let note) = event.type else {
                return nil
            }
            return event.beatPosition + note.duration
        }.max() ?? 0
        guard latestEnd > currentLength else { return clip }
        var grown = clip
        grown.timeRange = TimeRange(
            start: clip.timeRange.start,
            duration: TimePosition(beats: latestEnd,
                tempo: viewModel.transportState.tempo.bpm,
                sampleRate: viewModel.project.sampleRate))
        return grown
    }

    private func updateClip(_ clip: Clip, description: String = "Edit MIDI") {
        guard let trackID = viewModel.selectedTrackID,
              var track = viewModel.project.track(withID: trackID),
              let clipIndex = track.clips.firstIndex(where: { $0.id == clipID }) else { return }
        
        track.clips[clipIndex] = clip
        viewModel.updateTrack(track, description: description)
    }
    
    private func setupInitialView() {
        // Center on middle octaves
        visibleOctaveRange = 2...7
        // Note: Programmatic horizontal scrolling would require ScrollViewReader
        // The pianoRollInitialBeat is used but requires additional ScrollViewReader setup
    }
}

// MARK: - Note Drag Mode

enum NoteDragMode {
    case none
    case move
    case resizeStart
    case resizeEnd
}

// MARK: - Advanced Piano Key View

struct AdvancedPianoKeyView: View {
    let pitch: UInt8
    let noteHeight: CGFloat
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isPressed = false
    
    private var isBlackKey: Bool {
        [1, 3, 6, 8, 10].contains(Int(pitch) % 12)
    }
    
    private var noteName: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = Int(pitch) / 12 - 1
        let name = names[Int(pitch) % 12]
        return pitch % 12 == 0 ? "\(name)\(octave)" : ""
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isBlackKey ? Color.gray.opacity(0.4) : Color.white.opacity(0.1))
                .overlay(
                    Rectangle()
                        .fill(isPressed ? Color.accentColor.opacity(0.5) : Color.clear)
                )
            
            if !noteName.isEmpty {
                Text(noteName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1)
                .offset(y: noteHeight / 2 - 0.5)
        }
        .frame(height: noteHeight)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        onPress()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    onRelease()
                }
        )
    }
}

// MARK: - Advanced Note View

struct AdvancedNoteView: View {
    let event: MIDIEvent
    let noteData: NoteData
    let isSelected: Bool
    let pixelsPerBeat: Double
    let noteHeight: CGFloat
    let pitchOffset: Int
    let noteColor: Color
    let clipStartBeat: Double  // Absolute beat where clip starts
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
        // Calculate absolute position: clip start + note's relative position
        let absoluteBeat = clipStartBeat + event.beatPosition
        let x = CGFloat(absoluteBeat) * pixelsPerBeat
        let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
        let width = max(4, CGFloat(noteData.duration) * pixelsPerBeat)

        ZStack {
            // Note body
            RoundedRectangle(cornerRadius: 2)
                .fill(noteColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
                )

            // Velocity indicator (brightness)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(Double(noteData.velocity) / 127 * 0.3))

            // Resize handles (visible when selected)
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
        .offset(x: x, y: y + 1)  // Position based on actual note data, no drag offset
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
                    // Only determine drag mode once at the start
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
                    // Restore cursor
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

// MARK: - Velocity Bar

struct VelocityBar: View {
    let beat: Double
    let velocity: UInt8
    let isSelected: Bool
    let pixelsPerBeat: Double
    let height: CGFloat
    let onVelocityChange: (UInt8) -> Void
    let onVelocityCommit: () -> Void

    @State private var isDragging = false
    @State private var startVelocity: UInt8? = nil

    var body: some View {
        let x = CGFloat(beat) * pixelsPerBeat
        let barHeight = CGFloat(velocity) / 127 * height
        
        Rectangle()
            .fill(isSelected ? Color.accentColor : Color.blue)
            .frame(width: 4, height: barHeight)
            .offset(x: x, y: height - barHeight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startVelocity = velocity
                        }
                        let start = Int(startVelocity ?? velocity)
                        let change = Int((-value.translation.height / max(height, 1) * 127).rounded())
                        let newVelocity = UInt8(max(1, min(127, start + change)))
                        onVelocityChange(newVelocity)
                    }
                    .onEnded { _ in
                        isDragging = false
                        startVelocity = nil
                        onVelocityCommit()
                    }
            )
    }
}

// MARK: - Quantize Grid

enum QuantizeGrid: String, CaseIterable, Identifiable {
    case wholeNote = "1/1"
    case halfNote = "1/2"
    case quarterNote = "1/4"
    case eighthNote = "1/8"
    case sixteenthNote = "1/16"
    case thirtySecondNote = "1/32"
    case tripletQuarter = "1/4T"
    case tripletEighth = "1/8T"
    case tripletSixteenth = "1/16T"
    
    var id: String { rawValue }
    
    var division: Double {
        switch self {
        case .wholeNote: return 4.0
        case .halfNote: return 2.0
        case .quarterNote: return 1.0
        case .eighthNote: return 0.5
        case .sixteenthNote: return 0.25
        case .thirtySecondNote: return 0.125
        case .tripletQuarter: return 1.0 / 3.0 * 2
        case .tripletEighth: return 1.0 / 3.0
        case .tripletSixteenth: return 1.0 / 6.0
        }
    }
    
    var displayName: String {
        switch self {
        case .wholeNote: return "Whole Note"
        case .halfNote: return "Half Note"
        case .quarterNote: return "Quarter Note"
        case .eighthNote: return "Eighth Note"
        case .sixteenthNote: return "Sixteenth Note"
        case .thirtySecondNote: return "Thirty-Second Note"
        case .tripletQuarter: return "Quarter Triplet"
        case .tripletEighth: return "Eighth Triplet"
        case .tripletSixteenth: return "Sixteenth Triplet"
        }
    }
}

// MARK: - Quantize Dialog View

struct QuantizeDialogView: View {
    let noteCount: Int
    let onQuantize: (QuantizeGrid) -> Void
    let onCancel: () -> Void
    
    @State private var selectedGrid: QuantizeGrid = .sixteenthNote
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                Text("Quantize")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Content
            VStack(alignment: .leading, spacing: 16) {
                Text("\(noteCount) note\(noteCount == 1 ? "" : "s") selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quantize to Grid:")
                        .font(.headline)
                    
                    // Grid options
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(QuantizeGrid.allCases) { grid in
                            Button(action: { selectedGrid = grid }) {
                                VStack(spacing: 4) {
                                    Text(grid.rawValue)
                                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    Text(grid.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedGrid == grid ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(selectedGrid == grid ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            
            Divider()
            
            // Footer buttons
            HStack {
                Spacer()
                
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Quantize") {
                    onQuantize(selectedGrid)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Scroll Offset Preference Key

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

// MARK: - Empty Piano Roll View

/// Shown when a MIDI track is selected but has no clips
public struct EmptyPianoRollView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pianokeys")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No MIDI Clips")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Double-click on the track to create a clip, or use the pencil tool.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Create MIDI Clip") {
                // Create a new MIDI clip at the playhead
                let playheadBeat = viewModel.transportState.playheadBeats
                let tempo = viewModel.transportState.tempo.bpm
                viewModel.createMIDIClip(on: trackID, at: TimePosition(beats: playheadBeat, tempo: tempo), duration: 4.0)
                
                // Open piano roll for the new clip
                if let track = viewModel.project.track(withID: trackID),
                   let newClip = track.clips.last {
                    viewModel.openPianoRoll(for: newClip.id)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Piano Roll Placeholder View

/// Shown when piano roll panel is open but no MIDI track is selected
public struct PianoRollPlaceholderView: View {
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pianokeys")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("Select a MIDI or Instrument Track")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Click on a MIDI track to edit its notes here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
