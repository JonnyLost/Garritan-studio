import SwiftUI
import DAWCore

/// Searchable catalog of portable instruments in Studio's app-owned library.
/// The catalog reads lightweight manifests; samples are verified at load time.
public struct StudioSamplerLibraryBrowser: View {
    public let onChoose: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instruments: [StudioSamplerInstrumentPackage.LibraryItem] = []
    @State private var search = ""
    @State private var category = "All"
    @State private var errorMessage: String?
    @State private var pendingDeletion: URL?
    @State private var confirmingDeletion = false
    @State private var deleting = false

    public init(onChoose: @escaping (URL) -> Void) {
        self.onChoose = onChoose
    }

    private var categories: [String] {
        ["All"] + Array(Set(instruments.map(\.metadata.category))).sorted()
    }

    private var visible: [StudioSamplerInstrumentPackage.LibraryItem] {
        instruments.filter { item in
            (category == "All" || item.metadata.category == category) &&
            (search.isEmpty || item.metadata.name.localizedCaseInsensitiveContains(search) ||
             item.metadata.category.localizedCaseInsensitiveContains(search) ||
             item.metadata.tags.contains(where: {
                 $0.localizedCaseInsensitiveContains(search)
             }))
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Studio Instrument Library", systemImage: "square.stack.3d.up")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            HStack {
                TextField("Find instrument, category or tag", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 190)
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            if instruments.isEmpty {
                ContentUnavailableView(
                    "Your Instrument Library Is Empty",
                    systemImage: "square.stack",
                    description: Text("Save an instrument from the Mapping editor to make it available here. Packages contain their own recordings and instrument settings.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "pianokeys")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.metadata.name).font(.headline)
                            Text("\(item.metadata.category) · \(item.zoneCount) zones")
                                .font(.caption).foregroundStyle(.secondary)
                            if !item.metadata.tags.isEmpty {
                                Text(item.metadata.tags.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Load") {
                            onChoose(item.url)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .destructive) {
                            pendingDeletion = item.url
                            confirmingDeletion = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(deleting)
                        .help("Remove this saved package from the library")
                    }
                    .padding(.vertical, 5)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Text("\(visible.count) of \(instruments.count) instruments")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Library packages store independent sample copies.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 450)
        .onAppear(perform: refresh)
        .alert("Remove this instrument package?", isPresented: $confirmingDeletion) {
            Button("Remove Package", role: .destructive) {
                if let url = pendingDeletion { remove(url) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The saved package will be deleted. Original samples and recordings already imported into tracks will not be removed.")
        }
    }

    private func refresh() {
        do {
            instruments = try StudioSamplerInstrumentPackage.listLibrary()
            if !categories.contains(category) { category = "All" }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ url: URL) {
        deleting = true
        Task { @MainActor in
            defer {
                deleting = false
                pendingDeletion = nil
                refresh()
            }
            do {
                try await Task.detached(priority: .utility) {
                    try StudioSamplerInstrumentPackage.removeFromLibrary(url)
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
