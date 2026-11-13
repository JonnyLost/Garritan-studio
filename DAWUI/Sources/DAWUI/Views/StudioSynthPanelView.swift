import SwiftUI
import DAWCore

/// Studio Synth's unified native instrument interface. The layer overview
/// and focused engine editors are deliberately separate: switching tabs
/// never destroys a sound or silently disables another layer.
public struct StudioSynthPanelView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    public let trackID: TrackID
    @State private var focusedEngine: StudioSynthEngine?
    @State private var selectedLayerID: UUID?
    @State private var panelError: String?

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var patch: StudioSynthPatch {
        viewModel.project.track(withID: trackID)?.studioSynthPatch ?? StudioSynthPatch()
    }

    private var selectedLayer: StudioSynthLayer? {
        let matching = patch.layers.filter { layer in
            focusedEngine == nil || layer.engine == focusedEngine
        }
        return matching.first(where: { $0.id == selectedLayerID }) ?? matching.first
    }

    private var connected: Bool {
        guard let instrument = viewModel.playbackEngine.instrument(for: trackID),
              case .studioSynth = instrument else { return false }
        return true
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 28))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("STUDIO SYNTH")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(patch.isHybrid ? "Hybrid · \(patch.layers.count) layers" :
                         "Individual · \(patch.layers.count) layer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(connected ? "Audio connected" : "Engine unavailable",
                      systemImage: connected ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    viewModel.playbackEngine.playTestNote(on: trackID)
                } label: {
                    Label("Audition C4", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connected)
            }
            .padding(14)

            Divider()

            HStack(spacing: 8) {
                Button("Hybrid / Layers") { focusedEngine = nil }
                    .buttonStyle(.bordered)
                    .tint(focusedEngine == nil ? .cyan : .gray)

                ForEach(StudioSynthEngine.allCases) { engine in
                    Button(engine.title) {
                        focusedEngine = engine
                        selectedLayerID = patch.layers.first(where: {
                            $0.engine == engine
                        })?.id
                    }
                    .buttonStyle(.bordered)
                    .tint(focusedEngine == engine ? .cyan : .gray)
                    .disabled(!patch.layers.contains(where: { $0.engine == engine }))
                }
                Spacer()
                Menu {
                    Button("New Analog Instrument") {
                        replace(with: StudioSynthPatch.individual(.analog))
                    }
                    Button("New FM Instrument") {
                        replace(with: StudioSynthPatch.individual(.fm))
                    }
                    Button("New Wavetable Instrument") {
                        replace(with: StudioSynthPatch.individual(.wavetable))
                    }
                    Button("New Additive Instrument") {
                        replace(with: StudioSynthPatch.individual(.additive))
                    }
                    Button("New Analog + FM Hybrid") {
                        replace(with: StudioSynthPatch())
                    }
                } label: {
                    Label("New Sound", systemImage: "doc.badge.plus")
                }
                Menu {
                    Button("Analog Layer") { addLayer(.analog) }
                    Button("FM Layer") { addLayer(.fm) }
                    Button("Wavetable Layer") { addLayer(.wavetable) }
                    Button("Additive Layer") { addLayer(.additive) }
                } label: {
                    Label("Add Layer", systemImage: "plus")
                }
                .disabled(patch.layers.count >= 4)
            }
            .padding(12)
            Divider()

            if let panelError {
                HStack {
                    Label(panelError, systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Dismiss") { self.panelError = nil }
                }
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Select a layer to edit its native engine. All enabled layers play together; switching editor tabs does not affect the sound.")
                        .font(.caption).foregroundStyle(.secondary)

                    layerOverview

                    StudioSynthModulationView(viewModel: viewModel, trackID: trackID)
                    StudioSynthMIDILearnView(viewModel: viewModel, trackID: trackID)

                    if let layer = selectedLayer {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(layer.engine.title.uppercased()) ENGINE")
                                        .font(.headline)
                                    Text(layer.name)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if layer.engine == .analog {
                                    Menu {
                                        ForEach(StudioAnalogFactoryLibrary.presets) { preset in
                                            Button(preset.name) {
                                                loadAnalogPreset(preset.patch, layerID: layer.id)
                                            }
                                        }
                                    } label: {
                                        Label("Analog Factory Sounds", systemImage: "square.stack.3d.up")
                                    }
                                } else if layer.engine == .wavetable {
                                    Menu {
                                        ForEach(["Keys", "Lead", "Pad", "Bass", "Texture"],
                                                id: \.self) { family in
                                            Menu(family) {
                                                ForEach(StudioWavetableFactoryLibrary.presets.filter {
                                                    $0.family == family
                                                }) { preset in
                                                    Button(preset.name) {
                                                        loadWavetablePreset(preset.patch,
                                                                            layerID: layer.id)
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Wavetable Factory Sounds",
                                              systemImage: "waveform.path.ecg.rectangle")
                                    }
                                } else if layer.engine == .additive {
                                    Menu {
                                        ForEach(["Keys", "Winds", "Pads", "Bass",
                                                 "Plucks", "Textures"], id: \.self) { family in
                                            Menu(family) {
                                                ForEach(StudioAdditiveFactoryLibrary.presets.filter {
                                                    $0.family == family
                                                }) { preset in
                                                    Button(preset.name) {
                                                        loadAdditivePreset(
                                                            preset.patch, layerID: layer.id)
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Additive Factory Sounds",
                                              systemImage: "waveform.path")
                                    }
                                } else {
                                    Menu {
                                        ForEach(StudioFMFactoryLibrary.presets) { preset in
                                            Button(preset.name) {
                                                loadFMPreset(preset.patch, layerID: layer.id)
                                            }
                                        }
                                    } label: {
                                        Label("FM Factory Sounds", systemImage: "square.stack.3d.up")
                                    }
                                }
                            }
                            Divider()
                            if layer.engine == .analog {
                                analogEditor(layer)
                            } else if layer.engine == .wavetable {
                                wavetableEditor(layer)
                            } else if layer.engine == .additive {
                                additiveEditor(layer)
                            } else {
                                fmEditor(layer)
                            }
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 800, minHeight: 580)
        .onDisappear {
            viewModel.cancelStudioSynthMIDILearn(for: trackID)
        }
    }

    private var layerOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAYERS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(patch.layers) { layer in
                HStack(spacing: 10) {
                    Button {
                        selectedLayerID = layer.id
                        focusedEngine = layer.engine
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: layer.engine == .analog
                                  ? "waveform" : "waveform.path.ecg")
                            Text(layer.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .frame(width: 175, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedLayer?.id == layer.id ? Color.cyan : Color.primary)

                    Toggle("On", isOn: Binding(
                        get: { layer.enabled },
                        set: { enabled in
                            var changed = patch
                            guard let index = changed.layers.firstIndex(where: {
                                $0.id == layer.id
                            }) else { return }
                            changed.layers[index].enabled = enabled
                            replace(with: changed)
                        }
                    ))
                    .labelsHidden()
                    .disabled(layer.enabled &&
                              patch.layers.filter(\.enabled).count == 1)

                    Text("Level").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding<Double>(
                        get: { Double(currentLayer(layer.id)?.gain ?? layer.gain) },
                        set: { gain in
                            viewModel.setStudioSynthLayerMix(
                                for: trackID, layerID: layer.id,
                                gain: Float(gain),
                                pan: currentLayer(layer.id)?.pan ?? layer.pan)
                        }
                    ), in: 0...1)
                    .disabled(!layer.enabled)

                    Text("Pan").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding<Double>(
                        get: { Double(currentLayer(layer.id)?.pan ?? layer.pan) },
                        set: { pan in
                            viewModel.setStudioSynthLayerMix(
                                for: trackID, layerID: layer.id,
                                gain: currentLayer(layer.id)?.gain ?? layer.gain,
                                pan: Float(pan))
                        }
                    ), in: -1...1)
                    .frame(width: 100)
                    .disabled(!layer.enabled)

                    Button(role: .destructive) {
                        var changed = patch
                        changed.layers.removeAll { $0.id == layer.id }
                        // A deleted layer cannot retain modulation or MIDI
                        // Learn destinations; prune them with the layer.
                        changed.modulation?.routes.removeAll {
                            $0.layerID == layer.id
                        }
                        changed.midiControls?.mappings.removeAll {
                            $0.target.layerID == layer.id
                        }
                        if changed.validate() {
                            selectedLayerID = changed.layers.first?.id
                            replace(with: changed)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(patch.layers.count <= 1)
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func currentLayer(_ id: UUID) -> StudioSynthLayer? {
        patch.layers.first { $0.id == id }
    }

    private func replace(with newPatch: StudioSynthPatch) {
        guard newPatch.validate() else {
            panelError = "At least one layer must remain active, and a maximum of four layers is supported."
            return
        }
        do {
            try viewModel.updateStudioSynthPatch(newPatch, for: trackID)
            panelError = nil
            if !newPatch.layers.contains(where: { $0.id == selectedLayerID }) {
                selectedLayerID = newPatch.layers.first?.id
            }
            if let focusedEngine,
               !newPatch.layers.contains(where: { $0.engine == focusedEngine }) {
                self.focusedEngine = nil
            }
        } catch {
            panelError = error.localizedDescription
        }
    }

    private func addLayer(_ engine: StudioSynthEngine) {
        var changed = patch
        guard changed.layers.count < 4 else { return }
        let layer = StudioSynthLayer(engine: engine)
        changed.layers.append(layer)
        replace(with: changed)
        selectedLayerID = layer.id
        focusedEngine = engine
    }

    private func loadAnalogPreset(_ preset: StudioAnalogPatch, layerID: UUID) {
        var changed = patch
        guard let index = changed.layers.firstIndex(where: { $0.id == layerID }) else {
            return
        }
        changed.layers[index].analogPatch = preset
        replace(with: changed)
    }

    private func loadWavetablePreset(_ preset: StudioWavetablePatch, layerID: UUID) {
        var changed = patch
        guard let index = changed.layers.firstIndex(where: { $0.id == layerID }) else {
            return
        }
        changed.layers[index].wavetablePatch = preset
        replace(with: changed)
    }

    private func loadAdditivePreset(_ preset: StudioAdditivePatch, layerID: UUID) {
        var changed = patch
        guard let index = changed.layers.firstIndex(where: { $0.id == layerID }) else {
            return
        }
        changed.layers[index].additivePatch = preset
        replace(with: changed)
    }

    private func loadFMPreset(_ preset: StudioFMPatch, layerID: UUID) {
        var changed = patch
        guard let index = changed.layers.firstIndex(where: { $0.id == layerID }) else {
            return
        }
        changed.layers[index].fmPatch = preset
        replace(with: changed)
    }

    /// The native DSP parameter list determines which controls support
    /// continuous MIDI Learn; discrete waveform and algorithm pickers are
    /// deliberately excluded from arbitrary 7-bit CC sweeps.
    @ViewBuilder
    private func midiLearnActions(layerID: UUID,
                                  destination: StudioSynthModDestination) -> some View {
        if destination.isContinuouslyModulatable {
            let target = StudioSynthMIDIControlTarget.parameter(
                layerID: layerID, destination: destination)
            Button("Learn MIDI CC") {
                _ = viewModel.beginStudioSynthMIDILearn(
                    for: trackID, target: target)
            }
            if patch.midiControls?.mappings.contains(where: {
                $0.target == target
            }) == true {
                Button("Remove MIDI CC Assignment", role: .destructive) {
                    var changed = patch.midiControls ?? StudioSynthMIDIControlSettings()
                    changed.mappings.removeAll { $0.target == target }
                    _ = viewModel.setStudioSynthMIDIControls(changed, for: trackID)
                }
            }
        }
    }

    private func wavetableValue(_ parameter: StudioWavetableParameter,
                                layerID: UUID) -> Float {
        currentLayer(layerID)?.wavetablePatch?.value(for: parameter)
            ?? parameter.defaultValue
    }

    private func wavetableSlider(_ parameter: StudioWavetableParameter,
                                 layerID: UUID) -> some View {
        let value = wavetableValue(parameter, layerID: layerID)
        return HStack(spacing: 8) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Slider(value: Binding<Double>(
                get: {
                    parameter.position(for: wavetableValue(parameter, layerID: layerID))
                },
                set: { position in
                    viewModel.setStudioSynthWavetableParameter(
                        parameter, value: parameter.value(at: position),
                        for: trackID, layerID: layerID)
                }), in: 0...1)
                .tint(.cyan)
            Text(parameter.displayValue(value))
                .font(.caption.monospacedDigit())
                .frame(width: 74, alignment: .trailing)
        }
        .contextMenu {
            midiLearnActions(layerID: layerID, destination: .wavetable(parameter))
        }
    }

    private func wavetableEditor(_ layer: StudioSynthLayer) -> some View {
        let harmonics = (0..<16).map {
            wavetableValue(StudioWavetableParameter.partial($0)!, layerID: layer.id)
        }
        let position = wavetableValue(.osc1Position, layerID: layer.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WAVETABLE MORPH")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                    Text("Six spectral frames · original bandlimited oscillators")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Frame \(String(format: "%.2f", position)) / 5")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.cyan)
            }

            StudioWavetableWaveformPreview(position: Double(position),
                                            harmonics: harmonics)
                .frame(height: 245)
                .background(Color.black.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.cyan.opacity(0.22)))
                .accessibilityLabel("Wavetable waveform morph preview")

            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { index in
                    Button(["Sine", "Triangle", "Saw", "Square",
                            "Glass", "Custom"][index]) {
                        viewModel.setStudioSynthWavetableParameter(
                            .osc1Position, value: Float(index),
                            for: trackID, layerID: layer.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(position-Float(index)) < 0.4 ? .cyan : .gray)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(minimum: 260)),
                                GridItem(.flexible(minimum: 260))], spacing: 11) {
                ForEach(StudioWavetableParameter.allCases.filter {
                    $0.harmonicIndex == nil
                }, id: \.rawValue) { parameter in
                    wavetableSlider(parameter, layerID: layer.id)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CUSTOM HARMONIC WAVEFORM")
                        .font(.caption.weight(.bold))
                    Text("Select frame Custom (position 5) to hear your 16-partial design. Edits update the active native sound and are saved in this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use Custom") {
                    viewModel.setStudioSynthWavetableParameter(
                        .osc1Position, value: 5,
                        for: trackID, layerID: layer.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }

            LazyVGrid(columns: [GridItem(.flexible(minimum: 280)),
                                GridItem(.flexible(minimum: 280))], spacing: 9) {
                ForEach(0..<16, id: \.self) { index in
                    if let parameter = StudioWavetableParameter.partial(index) {
                        wavetableSlider(parameter, layerID: layer.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func analogEditor(_ layer: StudioSynthLayer) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(minimum: 260)),
                            GridItem(.flexible(minimum: 260))], spacing: 12) {
            ForEach(StudioAnalogParameter.allCases, id: \.rawValue) { parameter in
                let value = currentLayer(layer.id)?.analogPatch?.value(for: parameter)
                    ?? parameter.defaultValue
                if parameter == .oscillator1Wave || parameter == .oscillator2Wave {
                    Picker(parameter == .oscillator1Wave ? "OSC 1 Wave" : "OSC 2 Wave",
                           selection: Binding<Int>(
                            get: { Int(value) },
                            set: { number in
                                viewModel.setStudioSynthAnalogParameter(
                                    parameter, value: Float(number),
                                    for: trackID, layerID: layer.id)
                            })) {
                        ForEach(StudioAnalogWaveform.allCases) { wave in
                            Text(wave.title).tag(wave.rawValue)
                        }
                    }
                } else if parameter == .modulationTarget {
                    Picker("Mod Wheel", selection: Binding<Int>(
                        get: { Int(value) },
                        set: { number in
                            viewModel.setStudioSynthAnalogParameter(
                                parameter, value: Float(number),
                                for: trackID, layerID: layer.id)
                        })) {
                        Text("Vibrato").tag(0)
                        Text("Filter").tag(1)
                    }
                } else {
                    HStack {
                        Text(parameter.displayName)
                            .font(.caption)
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding<Double>(
                            get: {
                                parameter.position(for: currentLayer(layer.id)?
                                    .analogPatch?.value(for: parameter) ??
                                    parameter.defaultValue)
                            },
                            set: { position in
                                viewModel.setStudioSynthAnalogParameter(
                                    parameter, value: parameter.value(at: position),
                                    for: trackID, layerID: layer.id)
                            }), in: 0...1)
                        Text(parameter.displayValue(value))
                            .font(.caption.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                    .contextMenu {
                        midiLearnActions(layerID: layer.id,
                                         destination: .analog(parameter))
                    }
                }
            }
        }
    }

    private func additiveValue(_ parameter: StudioAdditiveParameter,
                               layerID: UUID) -> Float {
        currentLayer(layerID)?.additivePatch?.value(for: parameter)
            ?? parameter.defaultValue
    }

    private func additiveSlider(_ parameter: StudioAdditiveParameter,
                                layerID: UUID) -> some View {
        let value = additiveValue(parameter, layerID: layerID)
        return HStack(spacing: 8) {
            Text(parameter.name)
                .font(.caption)
                .frame(width: 110, alignment: .leading)
            Slider(value: Binding<Double>(
                get: {
                    parameter.position(for: additiveValue(parameter, layerID: layerID))
                },
                set: { fraction in
                    viewModel.setStudioSynthAdditiveParameter(
                        parameter, value: parameter.value(at: fraction),
                        for: trackID, layerID: layerID)
                }), in: 0...1)
                .tint(.mint)
            Text(parameter.displayValue(value))
                .font(.caption.monospacedDigit())
                .frame(width: 74, alignment: .trailing)
        }
        .contextMenu {
            midiLearnActions(layerID: layerID, destination: .additive(parameter))
        }
    }

    /// The amplitude bars are deliberately view-only: the horizontal
    /// sliders below are accessible, precise and participate in MIDI Learn.
    private func additiveEditor(_ layer: StudioSynthLayer) -> some View {
        let harmonics: [Float] = (0..<16).map {
            additiveValue(StudioAdditiveParameter.partial($0)!, layerID: layer.id)
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HARMONIC SCULPTOR")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.mint)
                    Text("16 sine partials · spectral evolution · original native additive voices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("16 PARTIALS")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.mint)
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<16, id: \.self) { index in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [.mint.opacity(0.45), .mint],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(height: max(3, CGFloat(harmonics[index]) * 125))
                        Text("\(index + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 160)
            .padding(12)
            .background(Color.black.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Current additive partial spectrum, harmonics 1 through 16")
            Text("Each harmonic is independently adjustable. Spectral Tilt shapes the entire spectrum; Evolution starts brighter or darker and gradually moves toward the sustained spectrum.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(minimum: 260)),
                                GridItem(.flexible(minimum: 260))], spacing: 11) {
                ForEach(StudioAdditiveParameter.allCases.filter {
                    $0.harmonicIndex == nil
                }, id: \.rawValue) { parameter in
                    additiveSlider(parameter, layerID: layer.id)
                }
            }
            Divider()
            Text("INDIVIDUAL HARMONICS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.mint)
            LazyVGrid(columns: [GridItem(.flexible(minimum: 260)),
                                GridItem(.flexible(minimum: 260))], spacing: 9) {
                ForEach(0..<16, id: \.self) { index in
                    if let parameter = StudioAdditiveParameter.partial(index) {
                        additiveSlider(parameter, layerID: layer.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fmEditor(_ layer: StudioSynthLayer) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(minimum: 260)),
                            GridItem(.flexible(minimum: 260))], spacing: 12) {
            ForEach(StudioFMParameter.allCases, id: \.rawValue) { parameter in
                let value = currentLayer(layer.id)?.fmPatch?.value(for: parameter)
                    ?? parameter.defaultValue
                if parameter == .algorithm {
                    Picker("FM Algorithm", selection: Binding<Int>(
                        get: { Int(value) },
                        set: { number in
                            viewModel.setStudioSynthFMParameter(
                                parameter, value: Float(number),
                                for: trackID, layerID: layer.id)
                        })) {
                        ForEach(StudioFMAlgorithm.allCases) { algorithm in
                            Text(algorithm.name).tag(algorithm.rawValue)
                        }
                    }
                } else if parameter == .modTarget {
                    Picker("Mod Wheel", selection: Binding<Int>(
                        get: { Int(value) },
                        set: { number in
                            viewModel.setStudioSynthFMParameter(
                                parameter, value: Float(number),
                                for: trackID, layerID: layer.id)
                        })) {
                        Text("Vibrato").tag(0)
                        Text("Brightness").tag(1)
                    }
                } else {
                    HStack {
                        Text(parameter.operatorIndex.map { "OP \($0 + 1) " } ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(parameter.name)
                            .font(.caption)
                            .frame(width: 88, alignment: .leading)
                        Slider(value: Binding<Double>(
                            get: {
                                parameter.position(for: currentLayer(layer.id)?
                                    .fmPatch?.value(for: parameter) ??
                                    parameter.defaultValue)
                            },
                            set: { position in
                                viewModel.setStudioSynthFMParameter(
                                    parameter, value: parameter.value(at: position),
                                    for: trackID, layerID: layer.id)
                            }), in: 0...1)
                        Text(parameter.displayValue(value))
                            .font(.caption.monospacedDigit())
                            .frame(width: 85, alignment: .trailing)
                    }
                    .contextMenu {
                        midiLearnActions(layerID: layer.id,
                                         destination: .fm(parameter))
                    }
                }
            }
        }
    }
}
