import SwiftUI
import DAWCore

/// Lightweight browser for the Apple DLS sampler already provided by macOS.
/// It selects a preset on the track's existing fallback sampler, never replaces
/// a native Studio Synth, ARIA instance, or an audio graph connection.
struct StudioAppleGeneralMIDIBrowserView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID

    @State private var searchText = ""
    @State private var category = "All"
    @State private var error: String?

    private let categories = [
        "All", "Keys", "Guitars", "Bass", "Strings", "Brass",
        "Woodwinds", "Synth", "World", "Percussion", "Other"
    ]

    private var selectedProgram: UInt8 {
        viewModel.project.track(withID: trackID)?.appleGeneralMIDIProgram ?? 0
    }

    private var visiblePrograms: [Int] {
        (0..<128).filter { index in
            let program = UInt8(index)
            return (category == "All" ||
                    StudioAppleGeneralMIDI.category(for: program) == category) &&
                   (searchText.isEmpty ||
                    StudioAppleGeneralMIDI.name(for: program).localizedCaseInsensitiveContains(searchText) ||
                    StudioAppleGeneralMIDI.family(for: program).localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple General MIDI").font(.title2.bold())
                    Text("128 built-in macOS DLS instrument sounds")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
                Button {
                    viewModel.playbackEngine.playTestNote(on: trackID)
                } label: {
                    Label("Try C4", systemImage: "play.fill")
                }
                .disabled(viewModel.playbackEngine.sampler(for: trackID) == nil)
            }
            HStack {
                TextField("Find a piano, guitar, pad, effect…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Family", selection: $category) {
                    ForEach(categories, id: \.self) { item in
                        Text(item == "All" ? "All Families" : item).tag(item)
                    }
                }
                .frame(width: 160)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visiblePrograms, id: \.self) { index in
                        let program = UInt8(index)
                        Button {
                            do {
                                try viewModel.setAppleGeneralMIDIProgram(id: trackID, program: program)
                                error = nil
                            } catch {
                                self.error = error.localizedDescription
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(format: "%03d", index + 1))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(StudioAppleGeneralMIDI.name(for: program))
                                        .font(.subheadline)
                                    Text(StudioAppleGeneralMIDI.family(for: program))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedProgram == program {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(8)
                            .background(selectedProgram == program ?
                                        Color.accentColor.opacity(0.13) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Each choice is stored with this track. MIDI channel and volume remain independent. The sound bank is provided by macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 530, minHeight: 465)
    }
}
