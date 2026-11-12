import SwiftUI
import DAWCore

/// Shared modulation editor used by *every* Studio Synth engine and Hybrid.
/// This panel edits only a versioned project patch; the audio graph itself is
/// not rebuilt when routing, amount or a source's controls change.
struct StudioSynthModulationView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    @State private var expanded = true
    @State private var editError: String?

    private var synthPatch: StudioSynthPatch {
        viewModel.project.track(withID: trackID)?.studioSynthPatch
            ?? StudioSynthPatch()
    }

    private var settings: StudioSynthModulationSettings {
        synthPatch.modulation ?? StudioSynthModulationSettings()
    }

    private func save(_ value: StudioSynthModulationSettings) {
        if viewModel.setStudioSynthModulation(value, for: trackID) {
            editError = nil
        } else {
            editError = "This modulation route or setting is not supported by the selected layer."
        }
    }

    private func changeRoute(_ id: UUID,
                             _ update: (inout StudioSynthModRoute) -> Void) {
        var changed = settings
        guard let index = changed.routes.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&changed.routes[index])
        save(changed)
    }

    private func addRoute() {
        guard settings.routes.count < 24,
              let first = synthPatch.layers.first(where: \.enabled) ??
                synthPatch.layers.first,
              let target = StudioSynthModDestination.available(
                for: first.engine).first else { return }
        var changed = settings
        changed.routes.append(StudioSynthModRoute(
            source: .lfo1, layerID: first.id, destination: target, depth: 0.25))
        save(changed)
    }

    private func deleteRoute(id: UUID) {
        var changed = settings
        changed.routes.removeAll { $0.id == id }
        save(changed)
    }

    private func settingSlider(
        _ title: String,
        keyPath: WritableKeyPath<StudioSynthModulationSettings, Float>,
        range: ClosedRange<Double>, logarithmic: Bool = false,
        unit: String = ""
    ) -> some View {
        let current = Double(settings[keyPath: keyPath])
        let value = Binding<Double>(
            get: {
                let v = Double(settings[keyPath: keyPath])
                if logarithmic {
                    return log(v / range.lowerBound) /
                        log(range.upperBound / range.lowerBound)
                }
                return (v - range.lowerBound) /
                    (range.upperBound - range.lowerBound)
            },
            set: { position in
                var new = settings
                let t = min(1, max(0, position))
                let result = logarithmic
                    ? range.lowerBound *
                      pow(range.upperBound / range.lowerBound, t)
                    : range.lowerBound +
                      (range.upperBound - range.lowerBound) * t
                new[keyPath: keyPath] = Float(result)
                save(new)
            })
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 104, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(.cyan)
            Text(String(format: "%.2f%@", current, unit))
                .font(.caption.monospacedDigit())
                .frame(width: 78, alignment: .trailing)
        }
    }

    /// An independent Free / Sync selector for each LFO. Nil in an old patch
    /// means Free mode, and its original Hz rate is never overwritten by Sync.
    private func lfoEditor(
        _ name: String, symbol: String,
        rate: WritableKeyPath<StudioSynthModulationSettings, Float>,
        sync: WritableKeyPath<StudioSynthModulationSettings, StudioSynthLFOSync?>
    ) -> some View {
        let currentSync = settings[keyPath: sync]
        return VStack(alignment: .leading, spacing: 8) {
            Label(name, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Picker("LFO Mode", selection: Binding<Bool>(
                get: { settings[keyPath: sync] != nil },
                set: { enabled in
                    var changed = settings
                    changed[keyPath: sync] = enabled ? (changed[keyPath: sync]
                        ?? StudioSynthLFOSync()) : nil
                    save(changed)
                })) {
                Text("Free").tag(false)
                Text("Sync").tag(true)
            }
            .pickerStyle(.segmented)
            if currentSync != nil {
                HStack(spacing: 8) {
                    Picker("Division", selection: Binding<StudioSynthLFONote>(
                        get: { settings[keyPath: sync]?.note ?? .quarter },
                        set: { note in
                            var changed = settings
                            var value = changed[keyPath: sync] ?? StudioSynthLFOSync()
                            value.note = note
                            changed[keyPath: sync] = value
                            save(changed)
                        })) {
                        ForEach(StudioSynthLFONote.allCases) { note in
                            Text(note.title).tag(note)
                        }
                    }
                    Picker("Timing", selection: Binding<StudioSynthLFOTiming>(
                        get: { settings[keyPath: sync]?.timing ?? .straight },
                        set: { timing in
                            var changed = settings
                            var value = changed[keyPath: sync] ?? StudioSynthLFOSync()
                            value.timing = timing
                            changed[keyPath: sync] = value
                            save(changed)
                        })) {
                        ForEach(StudioSynthLFOTiming.allCases) { timing in
                            Text(timing.title).tag(timing)
                        }
                    }
                }
                Text("Following project tempo · \(String(format: "%.1f", viewModel.project.tempo.bpm)) BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                settingSlider("Rate", keyPath: rate,
                              range: 0.03...15, logarithmic: true, unit: " Hz")
            }
        }
    }

    private func routeEditor(_ route: StudioSynthModRoute) -> some View {
        let layer = synthPatch.layers.first(where: { $0.id == route.layerID })
        let available = StudioSynthModDestination.available(
            for: layer?.engine ?? .analog)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { route.enabled },
                    set: { value in
                        changeRoute(route.id) { $0.enabled = value }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel("Enable modulation route")
                Spacer()
                Text(layer?.enabled == true ? "Active layer" : "Muted layer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    deleteRoute(id: route.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete modulation route")
            }

            HStack(spacing: 10) {
                Picker("Source", selection: Binding<StudioSynthModSource>(
                    get: { route.source },
                    set: { value in
                        changeRoute(route.id) { $0.source = value }
                    })) {
                    ForEach(StudioSynthModSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.cyan)

                Picker("Layer", selection: Binding<UUID>(
                    get: { route.layerID },
                    set: { value in
                        changeRoute(route.id) { edited in
                            edited.layerID = value
                            if let selected = synthPatch.layers.first(where: {
                                $0.id == value
                            }), let first = StudioSynthModDestination.available(
                                for: selected.engine).first {
                                edited.destination = first
                            }
                        }
                    })) {
                    ForEach(synthPatch.layers) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                Picker("Destination", selection: Binding<StudioSynthModDestination>(
                    get: { route.destination },
                    set: { value in
                        changeRoute(route.id) { $0.destination = value }
                    })) {
                    ForEach(available, id: \.self) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .frame(maxWidth: .infinity)

                Text("Amount")
                    .font(.caption)
                Slider(value: Binding<Double>(
                    get: { Double(route.depth) },
                    set: { depth in
                        changeRoute(route.id) { $0.depth = Float(depth) }
                    }), in: -1...1)
                    .tint(.cyan)
                    .frame(width: 126)
                Text(String(format: "%+.2f", route.depth))
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("A single modulation source can control any Analog, FM or Wavetable layer. Use positive or negative depth to combine several routes on one destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let editError {
                    Label(editError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 270)),
                    GridItem(.flexible(minimum: 270))
                ], spacing: 11) {
                    VStack(alignment: .leading, spacing: 8) {
                        lfoEditor("LFO 1 · Sine", symbol: "waveform.path",
                                  rate: \.lfo1Rate, sync: \.lfo1Sync)
                        lfoEditor("LFO 2 · Triangle", symbol: "waveform",
                                  rate: \.lfo2Rate, sync: \.lfo2Sync)
                        Label("Macro / MIDI", systemImage: "pianokeys")
                            .font(.subheadline.weight(.semibold))
                        settingSlider("Macro 1", keyPath: \.macro1, range: 0...1)
                        Text("CC1 follows incoming MIDI. Its shared value is global; native engine CC1 behavior is also preserved.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Shared Modulation Envelope", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.subheadline.weight(.semibold))
                        settingSlider("Attack", keyPath: \.envelopeAttack,
                                      range: 0.01...20, logarithmic: true, unit: " s")
                        settingSlider("Decay", keyPath: \.envelopeDecay,
                                      range: 0.01...20, logarithmic: true, unit: " s")
                        settingSlider("Sustain", keyPath: \.envelopeSustain,
                                      range: 0...1)
                        settingSlider("Release", keyPath: \.envelopeRelease,
                                      range: 0.01...20, logarithmic: true, unit: " s")
                        Text("The global envelope retriggers on note-on and releases after all held/sustained notes are released.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text("ROUTING MATRIX")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\(settings.routes.count) / 24")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        var changed = settings
                        changed.routes.removeAll()
                        save(changed)
                    } label: {
                        Label("Clear Routes", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.routes.isEmpty)

                    Button {
                        addRoute()
                    } label: {
                        Label("Add Route", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(settings.routes.count >= 24)
                }

                if settings.routes.isEmpty {
                    Text("No modulation routes yet. Add a route to connect an LFO, envelope, CC1 or Macro 1 to any active synthesis module.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(settings.routes) { route in
                        routeEditor(route)
                    }
                }

                Text("Control-rate modulation: 50 updates/sec while routes are active. Source and destination values are clamped to safe parameter ranges; the audio callback remains allocation- and lock-free.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.cyan)
                Text("SHARED MODULATION")
                    .font(.headline)
                Spacer()
                Text("\(settings.routes.filter(\.enabled).count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
