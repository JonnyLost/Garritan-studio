import SwiftUI
import DAWCore

/// Editable six-band custom room inside Studio's Orchestral Stage.
/// Estimates update locally; actual DSP changes only on explicit Apply,
/// with playback/recording stopped.
struct StudioAcousticRoomDesignerView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @State private var draft = StudioAcousticRoomDesign()

    private var cannotApply: Bool {
        !viewModel.isEngineReady ||
        viewModel.transportState.isPlaying ||
        viewModel.transportState.isRecording ||
        viewModel.isRecording
    }

    private var predicted: [Double] { draft.predictedRT60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Room name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 7) {
                dimensionSlider("Length", value: $draft.lengthMeters, bounds: 3...80)
                dimensionSlider("Width", value: $draft.widthMeters, bounds: 3...80)
                dimensionSlider("Height", value: $draft.heightMeters, bounds: 2.2...35)
            }

            HStack {
                Text("Room volume")
                Spacer()
                Text("\(Int(draft.volumeCubicMeters.rounded())) m³")
                    .monospacedDigit()
            }
            .font(.caption)

            materialPicker("Walls", selected: $draft.wallMaterial)
            materialPicker("Floor", selected: $draft.floorMaterial)
            materialPicker("Ceiling", selected: $draft.ceilingMaterial)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Wall treatment")
                    Spacer()
                    Text("\(Int(draft.treatedWallFraction * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                Slider(value: $draft.treatedWallFraction, in: 0...1, step: 0.05)
                materialPicker("Treatment", selected: $draft.wallTreatmentMaterial)
            }

            Picker("Estimate", selection: $draft.method) {
                ForEach(StudioRoomDecayEstimation.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.segmented)

            Divider()
            Text("Predicted RT60 by octave")
                .font(.caption.weight(.semibold))
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(Self.bandLabel(StudioAcousticRoomDesign.bandCentersHz[index]))
                        .font(.caption2)
                        .frame(width: 42, alignment: .leading)
                    ProgressView(value: min(1, predicted[index] / 10))
                        .frame(maxWidth: .infinity)
                    Text(String(format: "%.2f s", predicted[index]))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 62, alignment: .trailing)
                }
            }
            Text("Diffuse-field estimates only. Actual reflections, room modes, and microphone placement vary. DSP decay targets are limited to 0.2–15 seconds.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.applyAcousticRoomDesign(draft)
            } label: {
                Label("Apply Custom Acoustic Room", systemImage: "waveform.path")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(cannotApply)
            .help("Stops and safely reconfigures native reverb processing; save the project to retain this room.")

            if cannotApply {
                Text("Stop playback and recording before applying room changes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            draft = viewModel.project.dawState.acousticRoomDesign ?? StudioAcousticRoomDesign()
        }
    }

    private func dimensionSlider(_ title: String, value: Binding<Double>,
                                 bounds: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: bounds, step: 0.2)
            Text(String(format: "%.1f m", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 47, alignment: .trailing)
        }
    }

    private func materialPicker(_ title: String,
                                selected: Binding<StudioAcousticSurface>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Picker(title, selection: selected) {
                ForEach(StudioAcousticSurface.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 175)
        }
    }

    private static func bandLabel(_ frequency: Int) -> String {
        frequency >= 1_000 ? "\(frequency / 1_000)k Hz" : "\(frequency) Hz"
    }
}
