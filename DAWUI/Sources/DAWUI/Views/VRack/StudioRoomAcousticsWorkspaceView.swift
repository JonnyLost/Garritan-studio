import SwiftUI
import DAWCore

/// Native room selection and editing in Studio's existing resizable
/// bottom workspace. This is a UI relocation, not a new DSP or audio route.
/// Stage positioning stays in OrchestralStageView.
struct StudioRoomAcousticsWorkspaceView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    @State private var selectedTab: Tab = .library

    private enum Tab: String, CaseIterable, Identifiable {
        case library = "Room Library"
        case designer = "Room Designer"
        case controls = "Acoustic Controls"
        var id: String { rawValue }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Room Acoustics Section", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
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
            Text("Advanced decay and early-reflection tuning is calibrated offline. Continuous room morphing and virtual microphone controls are planned separately.")
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
