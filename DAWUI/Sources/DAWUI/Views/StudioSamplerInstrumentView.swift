import SwiftUI
import DAWCore

/// Three purpose-built instrument faces over ONE native Studio Sampler engine.
/// All currently interactive controls have a corresponding audio or mapping
/// action. Advanced techniques shown in design concepts are introduced only
/// when their processing is implemented, rather than as nonfunctional knobs.
public struct StudioSamplerInstrumentView: View {
    @ObservedObject public var viewModel: ProjectViewModel
    public let trackID: TrackID

    @State private var editMapping = false

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var patch: StudioSamplerPatch? {
        viewModel.project.track(withID: trackID)?.studioSamplerPatch
    }

    private var kind: StudioSamplerInstrumentKind {
        patch?.presentation ?? .general
    }

    private var isLoaded: Bool {
        guard let loaded = viewModel.playbackEngine.instrument(for: trackID),
              case .studioSampler = loaded else { return false }
        return true
    }

    private var usesDiskStreaming: Bool {
        guard let loaded = viewModel.playbackEngine.instrument(for: trackID),
              case .studioSampler(let sampler) = loaded else { return false }
        return sampler.isUsingDiskStreaming
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editMapping || patch?.isEmpty == true {
                // Empty instruments start in the mapping workspace so Add
                // Samples is immediately available without a file picker
                // appearing before the sampler interface itself.
                StudioSamplerMapView(viewModel: viewModel, trackID: trackID)
            } else if let patch {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch kind {
                        case .soloViolin: soloViolin(patch)
                        case .cinematicPercussion: cinematicPercussion(patch)
                        case .choirAndTextures: choirAndTextures(patch)
                        case .general: generalInstrument(patch)
                        }
                        articulationControls(patch)
                        HStack(alignment: .top, spacing: 14) {
                            controllerPanel
                            envelopePanel
                        }
                        sampleOverview(patch)
                        keyboard
                        Text("Round-robin takes and release-trigger samples are now configured in Edit Mapping. Legato transition modeling and microphone groups remain future milestones.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            } else {
                ContentUnavailableView(
                    "No Native Sampler",
                    systemImage: "waveform",
                    description: Text("Load your own samples through the instrument browser to build a playable instrument.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .cinematicPercussion ? "circle.grid.cross" :
                  kind == .choirAndTextures ? "waveform.path" : "waveform")
                .font(.title2)
                .foregroundStyle(.purple)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Studio Sampler — \(kind.title)")
                    .font(.title3.weight(.semibold))
                Text("\(patch?.zones.count ?? 0) mapped samples · original Studio playback engine")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isLoaded {
                Label(usesDiskStreaming ? "Hybrid RAM / Disk" : "RAM Playback",
                      systemImage: usesDiskStreaming ? "internaldrive" : "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Picker("Instrument layout", selection: Binding(
                get: { kind },
                set: { viewModel.setStudioSamplerInstrumentKind($0, for: trackID) }
            )) {
                ForEach(StudioSamplerInstrumentKind.allCases, id: \.self) { face in
                    Text(face.title).tag(face)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            if patch?.isEmpty == true {
                Label("Ready to add samples", systemImage: "plus.square.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    editMapping.toggle()
                } label: {
                    Label(editMapping ? "Performance" : "Edit Mapping",
                          systemImage: editMapping ? "slider.horizontal.3" : "pianokeys")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func generalInstrument(_ patch: StudioSamplerPatch) -> some View {
        banner(
            "Sample Instrument",
            subtitle: "Your own recorded sounds, mapped to the keyboard",
            symbol: "waveform",
            tint: .purple
        )
        HStack(alignment: .top, spacing: 14) {
            mappedSamples(patch, title: "Sample Zones", limit: 8)
            auditionCard(note: 60, title: "Audition C4", subtitle: "Hear the active sample mapping")
        }
    }

    @ViewBuilder
    private func soloViolin(_ patch: StudioSamplerPatch) -> some View {
        banner(
            "Solo Violin",
            subtitle: "Expressive sample layers for orchestral writing",
            symbol: "music.note",
            tint: .orange
        )
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recorded articulations", systemImage: "music.note.list")
                    .font(.subheadline.weight(.semibold))
                Text("Use the keyswitch map to select recorded articulations. Import separate recordings for each technique; Studio does not synthesize missing articulations.")

                    .font(.caption).foregroundStyle(.secondary)
                mappedSamples(patch, title: "Available Recordings", limit: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Label("Performance", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                auditionCard(note: 69, title: "Audition A4", subtitle: "Play violin's open A string")
                Text("CC1 can smoothly blend dynamic layers sharing a root note. CC11 controls overall expression.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cinematicPercussion(_ patch: StudioSamplerPatch) -> some View {
        banner(
            "Cinematic Percussion",
            subtitle: "Playable pads for drums, impacts, metals and recorded hits",
            symbol: "circle.grid.3x3.fill",
            tint: .red
        )
        VStack(alignment: .leading, spacing: 9) {
            Label("Hit Pads", systemImage: "square.grid.3x3")
                .font(.subheadline.weight(.semibold))
            Text("Each pad plays the actual root note assigned to a recorded sample.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                ForEach(Array(patch.zones.prefix(12).enumerated()), id: \.offset) { i, zone in
                    Button {
                        audition(zone.rootNote, velocity: 110)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.title2)
                            Text(noteName(zone.rootNote)).font(.caption.weight(.bold))
                            Text(zone.sampleURL.deletingPathExtension().lastPathComponent)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(Color.purple.opacity(i.isMultiple(of: 2) ? 0.15 : 0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isLoaded)
                }
            }
        }
    }

    @ViewBuilder
    private func choirAndTextures(_ patch: StudioSamplerPatch) -> some View {
        banner(
            "Choir & Textures",
            subtitle: "Performance morphing for layered voices and evolving sounds",
            symbol: "waveform.path.ecg",
            tint: .indigo
        )
        HStack(alignment: .top, spacing: 14) {
            mappedSamples(patch, title: "Choir / Texture Recordings", limit: 10)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Label("XY Expression", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                Text("Horizontal: CC1 layer dynamics · Vertical: CC11 expression")
                    .font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    let x = CGFloat(patch.dynamicsCC1 ?? 127) / 127
                    let y = 1 - CGFloat(patch.expressionCC11 ?? 127) / 127
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(
                                colors: [.indigo.opacity(0.28), .purple.opacity(0.08)],
                                startPoint: .bottomLeading, endPoint: .topTrailing
                            ))
                        Path { path in
                            path.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                            path.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                            path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                            path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                        }
                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                        Circle()
                            .fill(.purple)
                            .frame(width: 21, height: 21)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .position(x: max(11, min(geo.size.width - 11, x * geo.size.width)),
                                      y: max(11, min(geo.size.height - 11, y * geo.size.height)))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        guard geo.size.width > 0, geo.size.height > 0 else { return }
                        let dx = max(0, min(1, drag.location.x / geo.size.width))
                        let dy = 1 - max(0, min(1, drag.location.y / geo.size.height))
                        _ = viewModel.setStudioSamplerController(
                            1, value: UInt8((dx * 127).rounded()), for: trackID
                        )
                        _ = viewModel.setStudioSamplerController(
                            11, value: UInt8((dy * 127).rounded()), for: trackID
                        )
                    })
                }
                .frame(height: 180)
                .disabled(!isLoaded)
            }
            .frame(maxWidth: 310)
        }
    }

    @ViewBuilder
    private func articulationControls(_ patch: StudioSamplerPatch) -> some View {
        if let articulations = patch.articulations, !articulations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Articulations", systemImage: "music.note.list")
                    .font(.subheadline.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Button {
                            _ = viewModel.setStudioSamplerArticulation(0, for: trackID)
                        } label: {
                            VStack(spacing: 3) {
                                Text("Default / Sustain")
                                if let key = patch.defaultKeyswitchNote {
                                    Text("MIDI \(key)").font(.caption2).opacity(0.8)
                                }
                            }
                        }
                        .tint((patch.selectedArticulationID ?? 0) == 0 ? .purple : .gray)
                        ForEach(articulations) { articulation in
                            Button {
                                _ = viewModel.setStudioSamplerArticulation(
                                    articulation.id, for: trackID
                                )
                            } label: {
                                VStack(spacing: 3) {
                                    Text(articulation.name)
                                    Text("MIDI \(articulation.keyswitchNote)")
                                        .font(.caption2)
                                        .opacity(0.8)
                                }
                            }
                            .tint(patch.selectedArticulationID == articulation.id ? .purple : .gray)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isLoaded)
                }
                Text("Keyswitch MIDI notes also select articulations for subsequent notes. Existing held notes continue uninterrupted.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private var controllerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Expression & Dynamics", systemImage: "waveform.path")
                .font(.subheadline.weight(.semibold))
            controlRow("Dynamics", controller: 1, caption: "CC1 — dynamic level / layer blend")
            controlRow("Expression", controller: 11, caption: "CC11 — overall volume")
            Toggle("CC1 layer crossfade", isOn: Binding(
                get: { patch?.cc1Crossfade == true },
                set: { _ = viewModel.setStudioSamplerCC1Crossfade($0, for: trackID) }
            ))
            .disabled(!isLoaded)
            Text("CC1 crossfade applies to new notes and requires multiple samples mapped to the same root note. Existing held notes finish normally.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func controlRow(_ name: String, controller: UInt8, caption: String) -> some View {
        let value = controller == 1 ? (patch?.dynamicsCC1 ?? 127) : (patch?.expressionCC11 ?? 127)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption.weight(.medium))
                Spacer()
                Text("\(value)").font(.caption.monospacedDigit())
            }
            Slider(value: Binding(
                get: { Double(controller == 1 ? (patch?.dynamicsCC1 ?? 127) : (patch?.expressionCC11 ?? 127)) },
                set: { _ = viewModel.setStudioSamplerController(
                    controller, value: UInt8(clamping: Int($0.rounded())), for: trackID
                ) }
            ), in: 0...127)
            .disabled(!isLoaded)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private enum ADSRField {
        case attack, decay, sustain, release
    }

    private func envelopeValue(_ field: ADSRField) -> Double {
        let envelope = patch?.envelope ?? StudioSamplerEnvelope()
        switch field {
        case .attack: return Double(envelope.attackSeconds)
        case .decay: return Double(envelope.decaySeconds)
        case .sustain: return Double(envelope.sustainLevel)
        case .release: return Double(envelope.releaseSeconds)
        }
    }

    private func setEnvelopeValue(_ field: ADSRField, value: Double) {
        var envelope = patch?.envelope ?? StudioSamplerEnvelope()
        switch field {
        case .attack: envelope.attackSeconds = Float(value)
        case .decay: envelope.decaySeconds = Float(value)
        case .sustain: envelope.sustainLevel = Float(value)
        case .release: envelope.releaseSeconds = Float(value)
        }
        _ = viewModel.setStudioSamplerEnvelope(envelope, for: trackID)
    }

    private func envelopeControl(_ label: String, field: ADSRField,
                                 range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                Text(field == .sustain
                     ? String(format: "%.0f%%", envelopeValue(field) * 100)
                     : String(format: "%.0f ms", envelopeValue(field) * 1000))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { envelopeValue(field) },
                set: { setEnvelopeValue(field, value: $0) }
            ), in: range)
            .disabled(!isLoaded)
        }
    }

    private var envelopePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Amplitude Envelope (ADSR)", systemImage: "waveform.path")
                .font(.subheadline.weight(.semibold))
            envelopeControl("Attack", field: .attack, range: 0...5)
            envelopeControl("Decay", field: .decay, range: 0...5)
            envelopeControl("Sustain", field: .sustain, range: 0...1)
            envelopeControl("Release", field: .release, range: 0...10)
            Text("ADSR changes apply to newly played notes. Release works with mapped sustain loops.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func sampleOverview(_ patch: StudioSamplerPatch) -> some View {
        let groups = Dictionary(grouping: patch.zones, by: { $0.rootNote })
        let maxLayers = groups.values.map { $0.count }.max() ?? 0
        let releaseCount = patch.zones.filter { $0.isReleaseTrigger == true }.count
        let variations = Set(patch.zones.compactMap { $0.roundRobinIndex }).count
        return VStack(alignment: .leading, spacing: 12) {
            Label("Instrument Summary", systemImage: "square.stack.3d.up")
                .font(.subheadline.weight(.semibold))
            HStack {
                summary("Recorded samples", value: "\(patch.zones.count)")
                summary("Mapped roots", value: "\(groups.count)")
                summary("Max layers/root", value: "\(maxLayers)")
                summary("Release samples", value: "\(releaseCount)")
                summary("RR takes", value: "\(max(1, variations))")
            }
            Text("Samples are loaded from your imported recordings. This panel does not substitute synthetic sounds or bundled Garritan content.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mappedSamples(_ patch: StudioSamplerPatch, title: String, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "square.stack")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(patch.zones.prefix(limit).enumerated()), id: \.offset) { _, zone in
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(.purple)
                    Text(zone.sampleURL.lastPathComponent)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(noteName(zone.rootNote)) · V\(zone.lowestVelocity)–\(zone.highestVelocity) · RR\(Int(zone.roundRobinIndex ?? 0) + 1)\(zone.isReleaseTrigger == true ? " · Release" : "")")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if patch.zones.count > limit {
                Text("+ \(patch.zones.count - limit) more zones — Edit Mapping to view all")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func auditionCard(note: UInt8, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { audition(note) } label: {
                Label(title, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isLoaded)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func banner(_ title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .thin))
                .frame(width: 70, height: 70)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title.weight(.medium))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { audition(60) } label: {
                Label("Audition", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!isLoaded)
        }
        .padding(15)
        .background(LinearGradient(
            colors: [tint.opacity(0.19), Color.primary.opacity(0.035)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audition Keyboard · C3–B5")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 1) {
                ForEach(48..<84, id: \.self) { note in
                    let black = [1, 3, 6, 8, 10].contains(note % 12)
                    Button { audition(UInt8(note)) } label: {
                        VStack {
                            Spacer(minLength: 0)
                            if note % 12 == 0 {
                                Text("C\(note / 12 - 1)")
                                    .font(.system(size: 9))
                            }
                        }
                        .foregroundStyle(black ? Color.white : Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: black ? 44 : 65)
                        .background(black ? Color(white: 0.18) : Color(white: 0.90))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isLoaded)
                }
            }
        }
    }

    private func audition(_ note: UInt8, velocity: UInt8 = 95) {
        guard isLoaded else { return }
        viewModel.playbackEngine.playNotePreview(pitch: note, velocity: velocity, on: trackID)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            viewModel.playbackEngine.stopNotePreview(pitch: note, on: trackID)
        }
    }

    private func noteName(_ note: UInt8) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}
