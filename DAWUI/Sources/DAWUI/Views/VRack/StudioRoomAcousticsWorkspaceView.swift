import SwiftUI
import DAWCore

/// Native room selection and editing in Studio's existing resizable
/// bottom workspace. This is a UI relocation, not a new DSP or audio route.
/// Stage positioning stays in OrchestralStageView.
struct StudioRoomAcousticsWorkspaceView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    @State private var selectedTab: Tab = .library
    @State private var arrayToAdd: StudioMicrophoneArrayPreset = .spot

    private enum Tab: String, CaseIterable, Identifiable {
        case library = "Room Library"
        case designer = "Room Designer"
        case microphones = "Microphones"
        case controls = "Acoustic Controls"
        var id: String { rawValue }
    }

    private var roomDesign: StudioAcousticRoomDesign {
        viewModel.project.dawState.acousticRoomDesign ?? StudioAcousticRoomDesign()
    }

    private var microphoneObjects: [StudioVirtualMicrophone] {
        viewModel.project.dawState.virtualMicrophones ?? []
    }

    private var selectedMic: StudioVirtualMicrophone? {
        microphoneObjects.first { $0.id == viewModel.selectedVirtualMicrophoneID }
    }

    private func editSelectedMic(_ edit: (inout StudioVirtualMicrophone) -> Void) {
        guard var current = selectedMic else { return }
        edit(&current)
        viewModel.updateVirtualMicrophone(current)
    }

    private var canChangeRoom: Bool {
        viewModel.isEngineReady &&
        !viewModel.transportState.isPlaying &&
        !viewModel.transportState.isRecording &&
        !viewModel.isRecording
    }

    private var currentRoomID: String {
        viewModel.project.dawState.acousticRoomProfileID ?? "apple-medium-hall"
    }

    private var microphone: StudioVirtualMicrophoneSettings {
        viewModel.project.dawState.virtualMicrophoneSettings ?? StudioVirtualMicrophoneSettings()
    }

    private var microphonePerspectiveBinding: Binding<StudioMicrophonePerspective> {
        Binding(
            get: { microphone.perspective },
            set: { next in
                var current = microphone
                current.perspective = next
                viewModel.setVirtualMicrophone(current)
            }
        )
    }

    private var microphoneWidthBinding: Binding<Double> {
        Binding(
            get: { Double(microphone.safeWidth) },
            set: { next in
                var current = microphone
                current.stereoWidth = Float(next)
                viewModel.setVirtualMicrophone(current)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Room Acoustics Section", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 640)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Group {
                    switch selectedTab {
                    case .library:
                        libraryPanel
                    case .designer:
                        StudioAcousticRoomDesignerView(viewModel: viewModel)
                            .frame(maxWidth: 660, alignment: .leading)
                    case .microphones:
                        microphonePanel
                            .frame(maxWidth: 800, alignment: .leading)
                    case .controls:
                        acousticControls
                            .frame(maxWidth: 660, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.canvas)
        }
        .accessibilityIdentifier("room-acoustics-bottom-workspace")
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeading("Available Acoustic Spaces", symbol: "waveform.path")
            Text("Choose the room the orchestra performs in. Instrument positions remain in the Stage workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                roomTile(
                    id: "apple-medium-hall",
                    name: "Apple Medium Hall",
                    detail: "Original, tested fallback",
                    symbol: "speaker.wave.2"
                )
                ForEach(StudioRoomAcousticProfile.starterProfiles) { profile in
                    roomTile(
                        id: profile.id,
                        name: profile.name,
                        detail: "Experimental original algorithmic interpretation",
                        symbol: "building.columns"
                    )
                }
                roomTile(
                    id: StudioAcousticRoomDesign.profileID,
                    name: viewModel.project.dawState.acousticRoomDesign?.name ?? "Custom Acoustic Room",
                    detail: "Your six-band room design",
                    symbol: "slider.horizontal.3"
                )
            }

            HStack(spacing: 12) {
                Button("Edit Custom Room") { selectedTab = .designer }
                    .buttonStyle(.bordered)
                Text("Room changes require stopped transport. Project saves the selected room.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            selectionError
        }
    }

    private func roomTile(id: String, name: String, detail: String,
                          symbol: String) -> some View {
        Button {
            viewModel.selectConcertHallRoom(id: id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                    Spacer()
                    if id == currentRoomID {
                        Label("Selected", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                    }
                }
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(id == currentRoomID ? palette.accent : palette.primaryText)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .padding(12)
            .background(id == currentRoomID ? palette.accentMuted : palette.panel,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(id == currentRoomID ? palette.accent : palette.separator,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canChangeRoom)
        .accessibilityIdentifier("room-profile-" + id)
    }

    /// Mic objects are real saved Stage geometry, but deliberately do not
    /// create audio signals until the spill/mic-mixer routing milestone.
    private var microphonePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeading("Virtual Recording Microphones", symbol: "mic.fill")
            Text("Add and move individual microphone capsules in Stage. Arrays start with editable, conventional spacing; source pickup is a geometry preview, not live audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Picker("Add setup", selection: $arrayToAdd) {
                    ForEach(StudioMicrophoneArrayPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .frame(maxWidth: 260)
                Button("Add Microphones") {
                    viewModel.addVirtualMicrophoneArray(arrayToAdd)
                }
                .disabled(microphoneObjects.count + arrayToAdd.microphoneCount > 32)
                .accessibilityIdentifier("add-stage-microphones")
                Spacer()
                Text("\(microphoneObjects.count)/32 capsules")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if microphoneObjects.isEmpty {
                Text("No microphone objects yet. Add a spot mic, XY, ORTF, or Decca Tree. The original reverb remains unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 8)],
                          spacing: 8) {
                    ForEach(microphoneObjects) { mic in
                        Button {
                            viewModel.selectVirtualMicrophone(mic.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mic.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(mic.pattern.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.selectedVirtualMicrophoneID == mic.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .foregroundStyle(viewModel.selectedVirtualMicrophoneID == mic.id ?
                                             palette.accent : palette.primaryText)
                            .padding(10)
                            .background(
                                viewModel.selectedVirtualMicrophoneID == mic.id ?
                                    palette.accentMuted : palette.panel,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("virtual-mic-" + mic.id.uuidString)
                    }
                }
            }

            if let mic = selectedMic {
                Divider()
                HStack {
                    StudioSectionHeading("Selected Microphone", symbol: "scope")
                    Spacer()
                    Button("Remove Mic", role: .destructive) {
                        viewModel.removeVirtualMicrophone(id: mic.id)
                    }
                    .buttonStyle(.bordered)
                }
                TextField("Name", text: Binding(
                    get: { selectedMic?.name ?? "" },
                    set: { name in editSelectedMic { $0.name = String(name.prefix(80)) } }
                ))
                Picker("Pickup Pattern", selection: Binding(
                    get: { selectedMic?.pattern ?? .cardioid },
                    set: { value in editSelectedMic { $0.pattern = value } }
                )) {
                    ForEach(StudioMicrophonePolarPattern.allCases) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)

                microphoneCoordinate("Left / Right", keyPath: \.position.xMeters,
                                     limits: (-roomDesign.safeWidth / 2)...(roomDesign.safeWidth / 2))
                microphoneCoordinate("Front / Back", keyPath: \.position.yMeters,
                                     limits: 0...roomDesign.safeLength)
                microphoneCoordinate("Height", keyPath: \.position.zMeters,
                                     limits: 0...roomDesign.safeHeight)
                microphoneCoordinate("Direction", keyPath: \.azimuthDegrees,
                                     limits: -180...180, suffix: "°")
                microphoneCoordinate("Tilt", keyPath: \.elevationDegrees,
                                     limits: -90...90, suffix: "°")

                Text("Positions use meters. Front is y=0; microphones face toward the back of the stage at 0° direction. Drag the mic symbol in Stage to move its horizontal location.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                sourcePickupPreview(microphone: mic)
            }
            Divider()
            Text("Routing status: Geometry preview only. These microphone objects do not yet add audio channels or change the current mix. The next milestone will connect a preallocated source-to-microphone matrix and a separate mic mixer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func microphoneCoordinate(
        _ label: String,
        keyPath: WritableKeyPath<StudioVirtualMicrophone, Double>,
        limits: ClosedRange<Double>,
        suffix: String = " m"
    ) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.caption).frame(width: 90, alignment: .leading)
            Slider(
                value: Binding(
                    get: { selectedMic?[keyPath: keyPath] ?? limits.lowerBound },
                    set: { value in
                        editSelectedMic { $0[keyPath: keyPath] = value }
                    }
                ),
                in: limits
            )
            Text(String(format: "%.2f%@", selectedMic?[keyPath: keyPath] ?? 0, suffix))
                .font(.caption.monospacedDigit())
                .frame(width: 78, alignment: .trailing)
        }
    }

    private func sourcePickupPreview(microphone: StudioVirtualMicrophone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioSectionHeading("Estimated Section Spill", symbol: "waveform")
            Text("Idealized directional and distance estimates only—no instrument audio is routed through these microphones yet.")
                .font(.caption2).foregroundStyle(.secondary)

            let tracks = viewModel.project.tracks.filter {
                $0.type == .midi || $0.type == .instrument
            }
            if tracks.isEmpty {
                Text("Add instrument tracks to preview their relative pickup.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(tracks.prefix(8)) { track in
                    let source = StudioMicrophoneGeometry.approximateTrackPosition(
                        pan: track.pan, zone: track.stageReverbZone ?? 2,
                        room: roomDesign
                    )
                    let capture = StudioMicrophoneGeometry.capture(
                        source: source, microphone: microphone
                    )
                    HStack(spacing: 8) {
                        Text(track.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f m", capture.distanceMeters))
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1f ms", capture.propagationDelayMilliseconds))
                            .frame(width: 65, alignment: .trailing)
                        Text(String(format: "%.1f dB",
                                    20 * log10(max(1.0e-8,
                                                   abs(capture.estimatedDirectAmplitude)))))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
                if tracks.count > 8 {
                    Text("Showing first eight instrument sources")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var acousticControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeading("Orchestra Ambience", symbol: "slider.horizontal.3")
            Text("One shared hall keeps the orchestra in a cohesive space. Each track's wet send and early reflections follow its Stage position.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Overall Reverb")
                Spacer()
                Text("\(Int(viewModel.audioEngine.concertHallOverallReverb * 100))%")
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.audioEngine.concertHallOverallReverb) },
                    set: { viewModel.setConcertHallOverallReverb(Float($0)) }
                ),
                in: 0...2
            )
            Divider()
            StudioSectionHeading("Virtual Stereo Microphone", symbol: "mic")
            Picker("Listening Position", selection: microphonePerspectiveBinding) {
                ForEach(StudioMicrophonePerspective.allCases) { perspective in
                    Text(perspective.displayName).tag(perspective)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("virtual-microphone-position")
            HStack {
                Text("Stereo Width")
                Spacer()
                Text(String(format: "%.0f%%", Double(microphone.safeWidth) * 100))
                    .monospacedDigit()
            }
            Slider(value: microphoneWidthBinding, in: 0...1.5)
                .accessibilityIdentifier("virtual-microphone-stereo-width")
            Text(currentRoomID == "apple-medium-hall"
                ? "Virtual microphones are saved, but become audible only with a native room. The original Apple Hall remains unchanged."
                : "Move between conductor, main stereo pair and audience listening positions. The native room adjusts early reflections and direct sound without rebuilding the audio graph.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let track = viewModel.selectedTrack,
               track.type == .midi || track.type == .instrument {
                StudioSectionHeading("Selected Instrument", symbol: "music.note")
                Text(track.name).font(.subheadline.weight(.semibold))
                HStack {
                    Text("Stage Zone")
                    Spacer()
                    Text("\(track.stageReverbZone ?? 2)")
                }
                HStack {
                    Text("Pan")
                    Spacer()
                    Text(String(format: "%+.0f%%", Double(track.pan) * 100))
                }
                Text("Use Stage to change this instrument's pan, depth and wet send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose an instrument track to view its stage-related ambience.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Virtual microphones are an experimental listening model, not a measured mic array. Continuous geometry changes and advanced decay tuning remain future milestones.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            selectionError
        }
    }

    @ViewBuilder
    private var selectionError: some View {
        if let error = viewModel.acousticRoomSelectionError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
