import SwiftUI
import DAWCore

/// Studio Analog's traditional, native instrument panel. This is a view of
/// the underlying modular DSP graph, not a separate synthesizer or an AU UI.
/// All controls write to the render-safe atomic DSP parameters and persist in
/// the selected track's native StudioAnalogPatch.
public struct StudioAnalogPanelView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    public let trackID: TrackID

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var trackName: String {
        viewModel.project.track(withID: trackID)?.name ?? "Instrument Track"
    }

    private var isLoaded: Bool {
        guard let instrument = viewModel.playbackEngine.instrument(for: trackID),
              case .studioAnalog = instrument else { return false }
        return true
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("STUDIO ANALOG")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text("\(trackName)  ·  Native virtual analog  ·  8 voices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isLoaded ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(isLoaded ? "Engine connected" : "Audio engine unavailable")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                Button {
                    viewModel.resetStudioAnalogPatch(for: trackID)
                } label: {
                    Label("Initialize", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                Button {
                    viewModel.playbackEngine.playTestNote(on: trackID)
                } label: {
                    Label("Audition C4", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!isLoaded)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.orange)
                        Text("OSC 1 + OSC 2 + NOISE")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text("MIX")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text("FILTER")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text("VCA")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text("OUT")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Modular patching: next stage")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 295), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        AnalogModuleCard(title: "OSCILLATOR 1", symbol: "waveform", accent: .orange) {
                            AnalogWavePicker(viewModel: viewModel, trackID: trackID,
                                             parameter: .oscillator1Wave)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .oscillator1Level, accent: .orange)
                        }

                        AnalogModuleCard(title: "OSCILLATOR 2", symbol: "waveform", accent: .orange) {
                            AnalogWavePicker(viewModel: viewModel, trackID: trackID,
                                             parameter: .oscillator2Wave)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .oscillator2Level, accent: .orange)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .oscillator2Semitones, accent: .orange)
                        }

                        AnalogModuleCard(title: "MIXER + PULSE", symbol: "slider.horizontal.3",
                                         accent: .orange) {
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .noiseLevel, accent: .orange,
                                                   title: "Noise")
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .pulseWidth, accent: .orange)
                            Text("Pulse width affects both oscillators in pulse mode.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        AnalogModuleCard(title: "RESONANT FILTER", symbol: "line.diagonal",
                                         accent: .yellow) {
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .filterCutoff, accent: .yellow)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .resonance, accent: .yellow)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .filterEnvelopeDepth,
                                                   accent: .yellow)
                            Text("Low-pass · state-variable topology")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        AnalogModuleCard(title: "AMPLIFIER ENVELOPE", symbol: "chart.xyaxis.line",
                                         accent: .cyan) {
                            AnalogEnvelopePreview(
                                attack: value(.amplitudeAttack),
                                decay: value(.amplitudeDecay),
                                sustain: value(.amplitudeSustain),
                                release: value(.amplitudeRelease),
                                accent: .cyan
                            )
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .amplitudeAttack, accent: .cyan)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .amplitudeDecay, accent: .cyan)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .amplitudeSustain, accent: .cyan)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .amplitudeRelease, accent: .cyan)
                        }

                        AnalogModuleCard(title: "FILTER ENVELOPE", symbol: "chart.xyaxis.line",
                                         accent: .cyan) {
                            AnalogEnvelopePreview(
                                attack: value(.filterAttack),
                                decay: value(.filterDecay),
                                sustain: value(.filterSustain),
                                release: value(.filterRelease),
                                accent: .cyan
                            )
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .filterAttack, accent: .cyan)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .filterDecay, accent: .cyan)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .filterSustain, accent: .cyan)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .filterRelease, accent: .cyan)
                        }

                        AnalogModuleCard(title: "LOW-FREQUENCY OSCILLATOR",
                                         symbol: "waveform.path.ecg", accent: .mint) {
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .lfoRate, accent: .mint)
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .lfoDepth, accent: .mint)
                            Text("Sine LFO → filter cutoff · rate in Hz")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        AnalogModuleCard(title: "MASTER OUTPUT", symbol: "speaker.wave.3",
                                         accent: .purple) {
                            AnalogParameterControl(viewModel: viewModel, trackID: trackID,
                                                   parameter: .masterGain, accent: .purple)
                            Text("Feeds Studio's track fader, pan, meter and Concert Hall send.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func value(_ parameter: StudioAnalogParameter) -> Float {
        viewModel.studioAnalogValue(parameter, for: trackID)
    }
}

private struct AnalogModuleCard<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    let content: Content

    init(title: String, symbol: String, accent: Color,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.7)
                Spacer()
            }
            Rectangle()
                .fill(accent.opacity(0.5))
                .frame(height: 1)
            content
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(accent.opacity(0.23), lineWidth: 1))
    }
}

private struct AnalogParameterControl: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let parameter: StudioAnalogParameter
    let accent: Color
    var title: String? = nil

    private var value: Float {
        viewModel.studioAnalogValue(parameter, for: trackID)
    }

    var body: some View {
        HStack(spacing: 11) {
            AnalogDialMarker(position: parameter.position(for: value), accent: accent)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title ?? parameter.displayName)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 3)
                    Text(parameter.displayValue(value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding<Double>(
                    get: { parameter.position(for: value) },
                    set: { newPosition in
                        viewModel.setStudioAnalogParameter(parameter,
                            value: parameter.value(at: newPosition), for: trackID)
                    }
                ), in: 0...1)
                .tint(accent)
                .accessibilityLabel(title ?? parameter.displayName)
                .accessibilityValue(parameter.displayValue(value))
            }
        }
    }
}

/// The pointer and color arc visualize the same value as the native Slider,
/// which remains the primary accessible and keyboard-operable input.
private struct AnalogDialMarker: View {
    let position: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.08))
            Circle()
                .trim(from: 0, to: CGFloat(0.75 * min(1, max(0, position))))
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(3)
            Capsule()
                .fill(accent)
                .frame(width: 2.5, height: 12)
                .offset(y: -8)
                .rotationEffect(.degrees(-135 + 270 * position))
        }
    }
}

private struct AnalogWavePicker: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let parameter: StudioAnalogParameter

    var body: some View {
        Picker("Waveform", selection: Binding<Int>(
            get: { Int(viewModel.studioAnalogValue(parameter, for: trackID)) },
            set: { newWave in
                viewModel.setStudioAnalogParameter(parameter,
                                                 value: Float(newWave), for: trackID)
            }
        )) {
            ForEach(StudioAnalogWaveform.allCases) { waveform in
                Text(waveform.title).tag(waveform.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Waveform")
    }
}

/// A compact graphical ADSR curve, driven by the same persisted parameters
/// as the synth. The sustain plateau is not proportional to note duration.
private struct AnalogEnvelopePreview: View {
    let attack: Float
    let decay: Float
    let sustain: Float
    let release: Float
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let total = max(0.001, Double(attack + decay + release))
            let attackX = width * CGFloat(Double(attack) / total) * 0.74
            let decayX = attackX + width * CGFloat(Double(decay) / total) * 0.74
            let sustainX = width * 0.78
            let sustainY = height * CGFloat(1 - sustain)
            Path { path in
                path.move(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: attackX, y: 1))
                path.addLine(to: CGPoint(x: min(decayX, sustainX), y: sustainY))
                path.addLine(to: CGPoint(x: sustainX, y: sustainY))
                path.addLine(to: CGPoint(x: width, y: height))
            }
            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                              lineJoin: .round))
        }
        .frame(height: 48)
        .padding(8)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("ADSR envelope preview")
    }
}
