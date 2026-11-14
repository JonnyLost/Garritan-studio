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
        case mixer = "Mic Mixer"
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
                    case .mixer:
                        microphoneMixer
                            .frame(maxWidth: 850, alignment: .leading)
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

    /// The mic objects are project-persistent. The first audition renderer
    /// supports only four live microphone channels and sixteen sources.
    private var microphonePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeading("Virtual Recording Microphones", symbol: "mic.fill")
            Text("Add and move individual microphone capsules in Stage. Arrays have editable spacing, and the Mic Mixer lets you hear direct sound and simulated spill.")
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
                .disabled(microphoneObjects.count + arrayToAdd.microphoneCount > 32 ||
                          viewModel.audioEngine.isMicrophoneAuditionActive)
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
                    .disabled(viewModel.audioEngine.isMicrophoneAuditionActive)
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
            Text("The Mic Mixer offers explicit direct/spill audition for up to four capsules and sixteen sources. Add/remove capsules with audition off; position and pickup changes are live while auditioning. The normal mix remains the default.")
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
            Text("Estimated direction, distance and travel time. During Mic Mixer audition, these values drive each source-to-microphone Audio Unit.")
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

    private func editMixer(_ mic: StudioVirtualMicrophone,
                           _ mutate: (inout StudioMicrophoneChannelSettings) -> Void) {
        var copy = mic
        var settings = mic.mixer
        mutate(&settings)
        copy.mixerSettings = settings
        viewModel.updateVirtualMicrophone(copy)
    }

    private var microphoneMixer: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeading("Virtual Microphone Mixer", symbol: "slider.horizontal.3")
            Text("Every live microphone receives each participating source, with its own directional gain and sound-travel delay. Auditioning replaces the original dry mix temporarily; an adjustable shared room return adds ambience without a second dry orchestra.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let sourceCount = viewModel.project.tracks.filter {
                $0.type == .midi || $0.type == .instrument || $0.type == .audio
            }.count
            HStack(spacing: 12) {
                Button(viewModel.audioEngine.isMicrophoneAuditionActive ?
                        "Return to Original Mix" : "Audition Microphones") {
                    viewModel.setMicrophoneAuditionEnabled(
                        !viewModel.audioEngine.isMicrophoneAuditionActive)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canChangeRoom ||
                          (!viewModel.audioEngine.isMicrophoneAuditionActive &&
                           microphoneObjects.isEmpty))
                .accessibilityIdentifier("toggle-microphone-audition")
                Spacer()
                Text("\(min(4, microphoneObjects.count)) live mic channels · \(sourceCount) sources")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Experimental shared-history capture (one Audio Unit per source)",
                   isOn: Binding(
                       get: { viewModel.audioEngine.usesSharedMicrophoneMatrix },
                       set: { viewModel.audioEngine.setSharedMicrophoneMatrixEnabled($0) }
                   ))
                .toggleStyle(.switch)
                .font(.caption)
                .disabled(viewModel.audioEngine.isMicrophoneAuditionActive ||
                          !canChangeRoom)
                .accessibilityIdentifier("experimental-microphone-matrix")
            Text("Switch back to original capture with audition stopped. The experimental path still has the 16-source limit; both retain independent mic level, pan, mute, solo and alignment controls.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("Shared room return").font(.caption)
                Slider(value: Binding(
                    get: { Double(viewModel.audioEngine.microphoneRoomWetLevel) },
                    set: { viewModel.audioEngine.setMicrophoneRoomWetLevel(Float($0)) }
                ), in: 0...1)
                .accessibilityIdentifier("microphone-shared-room-wet")
                Text(String(format: "%.0f%%",
                            viewModel.audioEngine.microphoneRoomWetLevel * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 45, alignment: .trailing)
            }
            Text("One shared hall field is blended into microphone audition. It uses existing stage sends, not measured reflections at each capsule. Set to 0% for direct/spill-only comparison.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = viewModel.microphoneAuditionError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if microphoneObjects.isEmpty {
                Button("Add a Spot Microphone") {
                    viewModel.addVirtualMicrophoneArray(.spot)
                    selectedTab = .microphones
                }
                .buttonStyle(.bordered)
            } else {
                if microphoneObjects.count > AudioEngine.maximumAuditionMicrophones {
                    Text("This first live-audio implementation auditions the first four microphones. All other microphone objects remain saved and editable.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(microphoneObjects.prefix(AudioEngine.maximumAuditionMicrophones))) { mic in
                    micMixerStrip(mic)
                }
            }
            Divider()
            Text("Experimental direct-and-spill monitoring: capsule pickup, distance attenuation, air damping and propagation delay are audible. The original dry route is muted while auditioning; the shared room return has its own wet trim. Align shifts an entire capsule's capture by up to ±20 ms; it is a manual timing correction, not automatic phase matching. Independent mic stems and large orchestral matrices remain future milestones.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func micMixerStrip(_ mic: StudioVirtualMicrophone) -> some View {
        let settings = mic.mixer
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text(mic.name).font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(mic.pattern.displayName)
                    .font(.caption2).foregroundStyle(.secondary)
                Button(settings.isMuted ? "Unmute" : "Mute") {
                    editMixer(mic) { $0.isMuted.toggle() }
                }
                .buttonStyle(.bordered)
                Button(settings.isSolo ? "Unsolo" : "Solo") {
                    editMixer(mic) { $0.isSolo.toggle() }
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text("Level").frame(width: 42, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(mic.mixer.safeLevel) },
                    set: { level in
                        editMixer(mic) { $0.level = Float(level) }
                    }
                ), in: 0...2)
                Text(String(format: "%.0f%%", settings.safeLevel * 100))
                    .monospacedDigit().frame(width: 53)
            }
            HStack {
                Text("Align").frame(width: 42, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(mic.mixer.safeAlignmentMilliseconds) },
                    set: { value in
                        editMixer(mic) { $0.alignmentMilliseconds = Float(value) }
                    }
                ), in: -20...20, step: 0.1)
                .accessibilityIdentifier("mic-alignment-" + mic.id.uuidString)
                Text(String(format: "%+.1f ms",
                            settings.safeAlignmentMilliseconds))
                    .monospacedDigit().frame(width: 66)
                Button("Zero") {
                    editMixer(mic) { $0.alignmentMilliseconds = nil }
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text("Pan").frame(width: 42, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(mic.mixer.safePan) },
                    set: { value in
                        editMixer(mic) { $0.pan = Float(value) }
                    }
                ), in: -1...1)
                Text(String(format: "%+.0f", settings.safePan * 100))
                    .monospacedDigit().frame(width: 53)
            }
        }
        .font(.caption)
        .padding(12)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mic-mixer-" + mic.id.uuidString)
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
