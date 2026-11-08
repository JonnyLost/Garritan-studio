import SwiftUI
import Foundation
import DAWCore

// Read-only first pass. MIDI triggering is intentionally deferred until ARIA octave
// numbering and patch identity have been verified on the user's installation.
private struct GPOKeyswitchCatalog: Decodable {
    struct Assignment: Decodable, Identifiable {
        let note: String
        let articulation: String
        var id: String { note + articulation }
    }
    struct Patch: Decodable {
        let patch: String
        let keyswitches: [Assignment]
    }
    let patches: [Patch]

    static func load() -> GPOKeyswitchCatalog? {
        let fm = FileManager.default
        let name = "GPO5_keyswitch_catalog"
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: name, withExtension: "json") {
            candidates.append(bundled)
        }
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates += [
            root.appendingPathComponent("Resources/\(name).json"),
            root.appendingPathComponent("\(name).json"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/\(name).json")
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode(GPOKeyswitchCatalog.self, from: data) {
                return catalog
            }
        }
        return nil
    }
}

struct ArticulationsWorkspaceView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @State private var catalog = GPOKeyswitchCatalog.load()
    @State private var search = ""
    @State private var selectedPatchName: String?

    private var suggestedName: String {
        viewModel.selectedTrack?.name ?? ""
    }

    private var matchingPatches: [GPOKeyswitchCatalog.Patch] {
        guard let catalog else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.patches }
        return catalog.patches.filter { $0.patch.localizedCaseInsensitiveContains(query) }
    }

    private var activePatch: GPOKeyswitchCatalog.Patch? {
        guard let catalog else { return nil }
        if let selectedPatchName {
            return catalog.patches.first { $0.patch == selectedPatchName }
        }
        return catalog.patches.first { $0.patch.compare(suggestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Articulations").font(.headline)
                    Text("GPO5 keyswitch reference • \(viewModel.selectedTrack?.name ?? "No track selected")")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Reload Catalog") { catalog = GPOKeyswitchCatalog.load() }
                    .buttonStyle(.borderless)
            }
            .padding(14)
            Divider()

            if let catalog {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Find a GPO5 keyswitch patch", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                        Text("\(catalog.patches.count) documented KS patches")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                        List(matchingPatches, id: \.patch, selection: $selectedPatchName) { patch in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(patch.patch).font(.subheadline)
                                Text("\(patch.keyswitches.count) articulations")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            .tag(patch.patch)
                        }
                        .listStyle(.sidebar)
                    }
                    .frame(minWidth: 230, idealWidth: 290, maxWidth: 340)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let patch = activePatch {
                                Text(patch.patch).font(.title3.weight(.semibold))
                                Text("Reference assignments from the GPO5 owner's manual. These controls do not transmit MIDI yet.")
                                    .font(.caption).foregroundColor(.secondary)
                                ForEach(patch.keyswitches) { assignment in
                                    HStack(spacing: 16) {
                                        Text(assignment.note)
                                            .font(.system(.body, design: .monospaced).weight(.semibold))
                                            .frame(width: 52, alignment: .leading)
                                        Text(assignment.articulation)
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(7)
                                }
                            } else {
                                Text("Select a keyswitch patch from the list.")
                                    .foregroundColor(.secondary)
                                Text("The track name is used only as an initial suggestion; patch identity must be confirmed before MIDI triggering.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("GPO5 keyswitch catalog not found").font(.headline)
                    Text("Place GPO5_keyswitch_catalog.json in the project's Resources folder, beside the project root, or in your Downloads folder. Then select Reload Catalog.")
                    Text("The catalog contains manual-derived reference data. MIDI playback and automatic patch matching will be added after verification.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
    }
}
