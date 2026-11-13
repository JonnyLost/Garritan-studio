import SwiftUI
import DAWCore

/// A native, non-realtime composer for rhythmic and pitched ostinato patterns.
/// Pattern edits stay in the project; Apply creates ordinary, undoable MIDI clips.
public struct OstinatoWorkspaceView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject public var viewModel: ProjectViewModel

    @StateObject private var auditioner = OstinatoAuditioner()
    @State private var selectedPatternID: UUID?
    @State private var statusMessage: String?

    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }

    private var patterns: [OstinatoPattern] {
        viewModel.project.ostinatoPatterns ?? []
    }

    private var selectedPattern: OstinatoPattern? {
        patterns.first(where: { $0.id == selectedPatternID }) ?? patterns.first
    }

    private var selectedMIDITarget: Track? {
        guard let id = viewModel.selectedTrackID,
              let track = viewModel.project.track(withID: id),
              track.type == .instrument || track.type == .midi else { return nil }
        return track
    }

    public var body: some View {
        VStack(spacing: 0) {
            StudioWorkspaceHeader(
                "Ostinato Engine",
                subtitle: "Compose reusable patterns, then place editable MIDI on the timeline",
                symbol: "square.grid.3x3.fill"
            ) {
                Menu {
                    Button("Rhythmic Pattern") { createPattern(.rhythmic) }
                    Button("Melodic Pattern") { createPattern(.melodic) }
                } label: {
                    Label("New Pattern", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
            }

            if let pattern = selectedPattern {
                patternToolbar(pattern)
                Divider()
                patternGrid(pattern)
                Divider()
                applyBar(pattern)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 30))
                        .foregroundStyle(palette.accent)
                    Text("Start with a rhythmic or melodic pattern")
                        .font(.headline)
                    Text("Each pattern remains saved in your project, independently of the MIDI clips it generates.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("New Rhythm") { createPattern(.rhythmic) }
                        Button("New Motif") { createPattern(.melodic) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .background(palette.surface)
        .onDisappear { auditioner.stop() }
        .onReceive(viewModel.transportState.transportEventSubject) { _ in auditioner.stop() }
        .onReceive(viewModel.transportState.tempoSubject) { _ in auditioner.stop() }
        .onChange(of: viewModel.selectedTrackID) { _ in auditioner.stop() }
    }

    private func patternToolbar(_ pattern: OstinatoPattern) -> some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(patterns) { item in
                    Button(item.name) { auditioner.stop(); selectedPatternID = item.id; statusMessage = nil }
                }
            } label: {
                Label(pattern.name, systemImage: "chevron.down")
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)

            TextField("Pattern name", text: Binding(
                get: { selectedPattern?.name ?? "" },
                set: { name in editPattern { $0.name = name } }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 190)

            Text(pattern.mode == .rhythmic ? "Rhythmic lanes" : "Pitched lanes")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            Spacer(minLength: 4)

            Stepper(
                "Bars: \(pattern.bars)",
                value: Binding(
                    get: { selectedPattern?.bars ?? 1 },
                    set: { value in editPattern { $0.bars = min(8, max(1, value)) } }
                ),
                in: 1...8
            )
            .fixedSize()

            Picker("Grid", selection: Binding(
                get: { selectedPattern?.stepsPerBeat ?? 4 },
                set: { value in editPattern { $0.stepsPerBeat = value } }
            )) {
                Text("1/4").tag(1)
                Text("1/8").tag(2)
                Text("1/16").tag(4)
            }
            .frame(width: 108)
            .pickerStyle(.menu)

            Button(role: .destructive) {
                auditioner.stop()
                viewModel.deleteOstinatoPattern(id: pattern.id)
                selectedPatternID = patterns.first?.id
                statusMessage = nil
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete saved pattern; existing MIDI clips stay on the timeline")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func patternGrid(_ pattern: OstinatoPattern) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Click cells to toggle notes. Right-click an active note to set its velocity.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Button {
                    editPattern { editable in
                        let pitch = UInt8(min(127, 48 + editable.lanes.count * 5))
                        editable.lanes.append(OstinatoLane(
                            name: "Lane \(editable.lanes.count + 1)", pitch: pitch
                        ))
                    }
                } label: {
                    Label("Add Lane", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 3) {
                        Text("LANE / PITCH")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 170, alignment: .leading)
                        ForEach(0..<pattern.stepCount, id: \.self) { step in
                            Text(step % pattern.stepsPerBeat == 0 ?
                                 "\(step / pattern.stepsPerBeat + 1)" : "·")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 23)
                        }
                    }

                    ForEach(pattern.lanes) { lane in
                        HStack(spacing: 3) {
                            HStack(spacing: 5) {
                                TextField("Lane name", text: Binding(
                                    get: { selectedPattern?.lanes.first(where: { $0.id == lane.id })?.name ?? "" },
                                    set: { value in editLane(lane.id) { $0.name = value } }
                                ))
                                .textFieldStyle(.plain)
                                .frame(width: 84)

                                Stepper(value: Binding(
                                    get: { Int(selectedPattern?.lanes.first(where: { $0.id == lane.id })?.pitch ?? 60) },
                                    set: { value in
                                        editLane(lane.id) { $0.changePitch(to: UInt8(min(127, max(0, value)))) }
                                    }
                                ), in: 0...127) {
                                    Text(NoteData(pitch: lane.pitch).noteName)
                                        .font(.system(size: 10, design: .monospaced))
                                        .frame(minWidth: 26)
                                }
                                .controlSize(.small)
                                .fixedSize()
                            }
                            .frame(width: 170, alignment: .leading)

                            ForEach(0..<pattern.stepCount, id: \.self) { index in
                                let note = lane.steps.first(where: { $0.index == index })
                                Button {
                                    editLane(lane.id) { $0.toggleStep(at: index) }
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(note != nil ?
                                              palette.accent.opacity(Double(note!.velocity) / 127 * 0.75 + 0.25) :
                                              palette.separator.opacity(index % pattern.stepsPerBeat == 0 ? 0.8 : 0.3))
                                        .frame(width: 23, height: 25)
                                }
                                .buttonStyle(.plain)
                                .help("Step \(index + 1) — \(note == nil ? "Off" : "Velocity \(note!.velocity)")")
                                .contextMenu {
                                    if note != nil {
                                        ForEach([64, 90, 110, 127], id: \.self) { velocity in
                                            Button("Velocity \(velocity)") {
                                                editLane(lane.id) { editable in
                                                    if let i = editable.steps.firstIndex(where: { $0.index == index }) {
                                                        editable.steps[i].velocity = UInt8(velocity)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 10)
    }

    private func applyBar(_ pattern: OstinatoPattern) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let track = selectedMIDITarget {
                    Text("Destination: \(track.name)")
                        .font(.caption.weight(.medium))
                } else {
                    Text("Select a MIDI or instrument track to apply")
                        .font(.caption.weight(.medium))
                }
                Text(statusMessage ?? "Pattern source remains editable after MIDI placement")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()
            Toggle("Loop", isOn: $auditioner.loops)
                .toggleStyle(.checkbox)
                .fixedSize()
            Button {
                if auditioner.isAuditioning {
                    auditioner.stop()
                } else if let track = selectedMIDITarget,
                          !viewModel.transportState.isPlaying {
                    auditioner.start(pattern: pattern, track: track.id,
                        tempo: viewModel.transportState.tempo.bpm,
                        engine: viewModel.playbackEngine)
                }
            } label: {
                Label(auditioner.isAuditioning ? "Stop Preview" : "Preview",
                      systemImage: auditioner.isAuditioning ? "stop.fill" : "play.fill")
            }
            .disabled(!auditioner.isAuditioning &&
                (selectedMIDITarget == nil || pattern.midiEvents().isEmpty ||
                 viewModel.transportState.isPlaying))
            Text("\(pattern.midiEvents().count) notes · \(pattern.durationInBeats.formatted()) beats")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            Button {
                guard let track = selectedMIDITarget else { return }
                let beat = max(0, viewModel.transportState.playheadBeats)
                let success = viewModel.applyOstinatoPattern(pattern, to: track.id, atBeat: beat)
                statusMessage = success ? "MIDI clip created at beat \(beat.formatted())." :
                                          "No notes could be placed."
            } label: {
                Label("Apply MIDI at Playhead", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedMIDITarget == nil || pattern.midiEvents().isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func createPattern(_ mode: OstinatoMode) {
        auditioner.stop()
        let signature = viewModel.project.timeSignature
        let beats = Double(signature.numerator) * 4.0 / Double(max(1, signature.denominator))
        let pattern = OstinatoPattern.starter(mode: mode, beatsPerBar: beats)
        viewModel.saveOstinatoPattern(pattern)
        selectedPatternID = pattern.id
        statusMessage = nil
    }

    private func editPattern(_ update: (inout OstinatoPattern) -> Void) {
        guard var pattern = selectedPattern else { return }
        auditioner.stop()
        update(&pattern)
        viewModel.saveOstinatoPattern(pattern)
        statusMessage = nil
    }

    private func editLane(_ laneID: UUID, _ update: (inout OstinatoLane) -> Void) {
        editPattern { pattern in
            guard let i = pattern.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            update(&pattern.lanes[i])
        }
    }
}
