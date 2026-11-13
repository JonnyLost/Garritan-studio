import SwiftUI
import DAWCore

/// MIDI CC assignment editor shared by Analog, FM, Wavetable and Hybrid.
/// Right-click a supported parameter slider to learn it directly, or learn
/// Macro 1 here. Every assignment belongs to the saved Studio Synth patch.
struct StudioSynthMIDILearnView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    @State private var expanded = true

    private var patch: StudioSynthPatch {
        viewModel.project.track(withID: trackID)?.studioSynthPatch
            ?? StudioSynthPatch()
    }

    private var controls: StudioSynthMIDIControlSettings {
        patch.midiControls ?? StudioSynthMIDIControlSettings()
    }

    private var learning: StudioSynthMIDILearnRequest? {
        guard let pending = viewModel.studioSynthMIDILearnRequest,
              pending.trackID == trackID else { return nil }
        return pending
    }

    private func title(for target: StudioSynthMIDIControlTarget) -> String {
        switch target {
        case .macro1: return "Shared Macro 1"
        case .parameter(let id, let destination):
            let name = patch.layers.first(where: { $0.id == id })?.name ?? "Layer"
            return "\(name) · \(destination.title)"
        }
    }

    private func change(_ id: UUID,
                        _ edit: (inout StudioSynthMIDIControlMapping) -> Void) {
        var updated = controls
        guard let index = updated.mappings.firstIndex(where: { $0.id == id }) else {
            return
        }
        edit(&updated.mappings[index])
        _ = viewModel.setStudioSynthMIDIControls(updated, for: trackID)
    }

    private func remove(_ id: UUID) {
        var updated = controls
        updated.mappings.removeAll { $0.id == id }
        _ = viewModel.setStudioSynthMIDIControls(updated, for: trackID)
    }

    private func mappingEditor(_ mapping: StudioSynthMIDIControlMapping)
        -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Toggle("On", isOn: Binding(
                    get: { controls.mappings.first(where: { $0.id == mapping.id })?
                        .enabled ?? false },
                    set: { value in change(mapping.id) { $0.enabled = value } }
                ))
                .toggleStyle(.checkbox)
                Text(title(for: mapping.target))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("CC \(mapping.controller)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.cyan)
                Picker("Channel", selection: Binding<Int>(
                    get: { mapping.channel.map { Int($0) + 1 } ?? 0 },
                    set: { value in
                        change(mapping.id) {
                            $0.channel = value == 0 ? nil : UInt8(value - 1)
                        }
                    })) {
                    Text("Omni").tag(0)
                    ForEach(1...16, id: \.self) { channel in
                        Text("Ch \(channel)").tag(channel)
                    }
                }
                .labelsHidden()
                .frame(width: 84)
                Button("Re-Learn") {
                    _ = viewModel.beginStudioSynthMIDILearn(
                        for: trackID, target: mapping.target)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) { remove(mapping.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this MIDI CC assignment")
            }
            HStack(spacing: 10) {
                Text("Min").frame(width: 34, alignment: .leading)
                Slider(value: Binding<Double>(
                    get: { Double(mapping.minimum) },
                    set: { value in
                        change(mapping.id) { $0.minimum = Float(value) }
                    }), in: 0...1)
                Text("\(Int(mapping.minimum * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                Text("Max").frame(width: 34, alignment: .leading)
                Slider(value: Binding<Double>(
                    get: { Double(mapping.maximum) },
                    set: { value in
                        change(mapping.id) { $0.maximum = Float(value) }
                    }), in: 0...1)
                Text("\(Int(mapping.maximum * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    Label("MIDI LEARN & PERFORMANCE",
                          systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(controls.mappings.count) mappings")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if expanded {
                Text("Right-click a supported Analog, FM or Wavetable slider and choose Learn MIDI CC. Move a controller to assign it. One CC can control multiple layers. Arm the synth track to hear live controller changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        _ = viewModel.beginStudioSynthMIDILearn(
                            for: trackID, target: .macro1)
                    } label: {
                        Label("Learn Macro 1", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if let learning {
                        Text("Learning: \(title(for: learning.target)) — move a MIDI control")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Button("Cancel") {
                            viewModel.cancelStudioSynthMIDILearn(for: trackID)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if controls.mappings.isEmpty {
                    Text("No MIDI CC assignments. Learn Macro 1 or use a parameter's context menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controls.mappings) { mapping in
                        mappingEditor(mapping)
                    }
                }
                Text("Min and Max set the MIDI CC sweep range. Set Min higher than Max to reverse it. Assignments are saved with the project; current controller movements do not overwrite the original sound.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}
