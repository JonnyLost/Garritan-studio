import SwiftUI
import DAWCore

/// Traditional front panel for the original Studio FM renderer. Four
/// independent operators and four audio-rate routing algorithms share
/// the same in-process synthesis engine (no plugin editor or AU host).
public struct StudioFMPanelView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    public let trackID: TrackID
    @State private var errorMessage: String?

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var connected: Bool {
        guard let instrument = viewModel.playbackEngine.instrument(for: trackID),
              case .studioFM = instrument else { return false }
        return true
    }

    private var algorithm: StudioFMAlgorithm {
        StudioFMAlgorithm(rawValue: Int(viewModel.studioFMValue(.algorithm, for: trackID)))
            ?? .serial
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.cyan)
                    .frame(width: 38, height: 38)
                    .background(Color.cyan.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("STUDIO FM")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text("\(trackName) · Original 4-operator FM · 8 voices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle()
                        .fill(connected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(connected ? "Engine connected" : "Audio engine unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    do {
                        try viewModel.resetStudioFMPatch(for: trackID)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
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
                .tint(.cyan)
                .disabled(!connected)
            }
            .padding(14)

            Divider()

            if let errorMessage {
                HStack {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    algorithmSelector

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("OP1 is the main audible carrier. OP2–OP4 create harmonics by modulating other operators; all four are audible in Parallel mode.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 235), spacing: 12),
                            GridItem(.flexible(minimum: 235), spacing: 12)
                        ], spacing: 12
                    ) {
                        ForEach(0..<4, id: \.self) { index in
                            StudioFMOperatorCard(viewModel: viewModel,
                                                 trackID: trackID,
                                                 index: index)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        StudioFMControlCard(title: "GLOBAL", systemImage: "dial.medium") {
                            StudioFMParameterSlider(viewModel: viewModel, trackID: trackID,
                                                    parameter: .feedback)
                            StudioFMParameterSlider(viewModel: viewModel, trackID: trackID,
                                                    parameter: .bendRange)
                            StudioFMParameterSlider(viewModel: viewModel, trackID: trackID,
                                                    parameter: .outputGain)
                        }
                        Text("Pitch bend responds to the MIDI wheel; CC64 sustains notes. All sound synthesis happens directly inside Studio, using no external samples or plugin.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 540, minHeight: 410)
    }

    private var trackName: String {
        viewModel.project.track(withID: trackID)?.name ?? "Instrument Track"
    }

    private var algorithmSelector: some View {
        StudioFMControlCard(title: "FM ALGORITHM",
                            systemImage: "point.3.connected.trianglepath.dotted") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Routing", selection: Binding<Int>(
                        get: { algorithm.rawValue },
                        set: { index in
                            viewModel.setStudioFMParameter(.algorithm,
                                value: Float(index), for: trackID)
                        }
                    )) {
                        ForEach(StudioFMAlgorithm.allCases) { selection in
                            Text(selection.name).tag(selection.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 470)
                    Text(algorithm.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SIGNAL ROUTING")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(algorithm.diagram)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                        .accessibilityLabel(algorithm.description)
                }
                .padding(10)
                .background(Color.cyan.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
}

private struct StudioFMOperatorCard: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let index: Int

    private var isCarrier: Bool { index == 0 }
    private var accent: Color { isCarrier ? .cyan : .orange }

    var body: some View {
        StudioFMControlCard(
            title: "OPERATOR \(index + 1)",
            systemImage: isCarrier ? "speaker.wave.2" : "waveform"
        ) {
            HStack {
                Text(isCarrier ? "CARRIER" : "MODULATOR / CARRIER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                Spacer()
                Text("Sine")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ForEach(StudioFMOperatorControl.allCases, id: \.rawValue) { control in
                if let parameter = StudioFMParameter.op(index, control) {
                    StudioFMParameterSlider(viewModel: viewModel,
                                            trackID: trackID, parameter: parameter)
                }
            }
        }
    }
}

private struct StudioFMControlCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }
}

private struct StudioFMParameterSlider: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let parameter: StudioFMParameter

    private var value: Float {
        viewModel.studioFMValue(parameter, for: trackID)
    }

    private var binding: Binding<Double> {
        Binding(
            get: { parameter.position(for: value) },
            set: { position in
                viewModel.setStudioFMParameter(parameter, value: parameter.value(at: position),
                                               for: trackID)
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(parameter.name)
                .font(.caption)
                .frame(width: 63, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: binding, in: 0...1)
                .tint(.cyan)
                .accessibilityLabel(parameter.name)
            Text(parameter.displayValue(value))
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
    }
}
