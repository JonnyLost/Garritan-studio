import SwiftUI
import DAWCore
import DAWUI

/// Studio's starter layouts intentionally contain no loaded commercial instruments.
/// Users choose their own Garritan programs or native Studio instruments afterward.
enum StudioProjectTemplate: String, CaseIterable, Identifiable {
    case symphonic, chamber, film, hybrid, songwriting, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .symphonic: return "Symphonic Orchestra"
        case .chamber: return "Chamber Ensemble"
        case .film: return "Film Scoring"
        case .hybrid: return "Electronic & Hybrid"
        case .songwriting: return "Songwriting & Recording"
        case .blank: return "Blank Project"
        }
    }

    var subtitle: String {
        switch self {
        case .symphonic: return "Full orchestra template"
        case .chamber: return "Intimate ensemble template"
        case .film: return "Scoring-to-picture template"
        case .hybrid: return "Orchestral + modern template"
        case .songwriting: return "Composition & production template"
        case .blank: return "Start with a clean session"
        }
    }

    var group: String {
        switch self {
        case .symphonic: return "Orchestral"
        case .chamber: return "Ensemble"
        case .film: return "Scoring"
        case .hybrid: return "Hybrid"
        case .songwriting: return "Songwriting"
        case .blank: return "All Templates"
        }
    }

    var symbol: String {
        switch self {
        case .symphonic: return "music.note.list"
        case .chamber: return "music.quarternote.3"
        case .film: return "film.stack"
        case .hybrid: return "waveform.path"
        case .songwriting: return "mic"
        case .blank: return "plus.rectangle.on.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .symphonic: return Color(red: 0.64, green: 0.36, blue: 0.19)
        case .chamber: return Color(red: 0.53, green: 0.38, blue: 0.31)
        case .film: return Color(red: 0.30, green: 0.38, blue: 0.50)
        case .hybrid: return Color(red: 0.22, green: 0.43, blue: 0.57)
        case .songwriting: return Color(red: 0.47, green: 0.31, blue: 0.23)
        case .blank: return Color(red: 0.58, green: 0.49, blue: 0.37)
        }
    }

    func makeProject() -> Project {
        var project = ProjectFactory.createNewProject(name: title, includeDefaultTracks: false)
        let tracks: [(String, TrackType)] 
        switch self {
        case .symphonic:
            tracks = [("Strings", .instrument), ("Woodwinds", .instrument),
                      ("Brass", .instrument), ("Percussion", .instrument),
                      ("Harp & Keyboards", .instrument)]
        case .chamber:
            tracks = [("Violin", .instrument), ("Viola", .instrument),
                      ("Cello", .instrument), ("Piano", .instrument)]
        case .film:
            tracks = [("Strings", .instrument), ("Woodwinds", .instrument),
                      ("Brass", .instrument), ("Percussion", .instrument),
                      ("Synth & Textures", .instrument), ("Guide Audio", .audio)]
        case .hybrid:
            tracks = [("Orchestral Layer", .instrument), ("Synth 1", .instrument),
                      ("Synth 2", .instrument), ("Percussion", .instrument),
                      ("Audio", .audio)]
        case .songwriting:
            tracks = [("Lead Vocal", .audio), ("Guitar", .audio),
                      ("Keyboard", .instrument), ("Backing Vocals", .audio)]
        case .blank:
            tracks = []
        }
        for (index, entry) in tracks.enumerated() {
            let color: TrackColor = entry.1 == .audio ? .blue : (index.isMultiple(of: 2) ? .green : .gray)
            project.addTrack(Track(name: entry.0, type: entry.1, color: color))
        }
        return project
    }
}

/// A native, accessible startup surface. Decorative watercolor artwork can be
/// swapped in per card later without changing template identities or workflow.
struct StudioTemplateManagerView: View {
    @Environment(\.studioPalette) private var palette
    @EnvironmentObject private var appState: AppState

    @State private var selected: StudioProjectTemplate = .symphonic
    @State private var filter: String = "All Templates"
    @State private var query = ""

    private let filters = ["All Templates", "Orchestral", "Ensemble", "Scoring", "Hybrid", "Songwriting"]
    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 410), spacing: 18)]

    private var matchingTemplates: [StudioProjectTemplate] {
        StudioProjectTemplate.allCases.filter { template in
            (filter == "All Templates" || template.group == filter) &&
            (query.isEmpty || template.title.localizedCaseInsensitiveContains(query) ||
             template.subtitle.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                header
                filterBar
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(matchingTemplates) { template in
                            TemplateSelectionCard(
                                template: template,
                                isSelected: selected == template
                            ) { selected = template }
                        }
                    }
                    .padding(25)
                    .frame(maxWidth: .infinity)
                }
                footer
            }
        }
        .background(palette.canvas)
        .frame(minWidth: 900, minHeight: 650)
        .tint(palette.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 37, weight: .ultraLight))
                    .foregroundStyle(palette.accent)
                Text("GARRITAN")
                    .tracking(3)
                Text("STUDIO")
                    .tracking(5)
            }
            .font(.system(size: 17, weight: .semibold, design: .serif))
            .foregroundStyle(palette.primaryText)
            .padding(.bottom, 32)

            sidebarButton("Template Manager", symbol: "square.grid.2x2", selected: true) {}
            sidebarButton("Open Project…", symbol: "folder") { appState.openProject() }
            Divider().padding(.vertical, 24)

            Label("RECENT PROJECTS", systemImage: "clock")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(palette.secondaryText)
                .padding(.bottom, 11)

            ForEach(appState.recentProjectsManager.recentProjects.prefix(7)) { project in
                sidebarButton(project.name, symbol: "doc.text", selected: false) {
                    Task { await appState.openProject(at: project.fileURL) }
                }
            }
            if appState.recentProjectsManager.recentProjects.isEmpty {
                Text("Your recent projects will appear here.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            Text("CREATE SOMETHING EXTRAORDINARY")
                .font(.system(size: 9, weight: .medium, design: .serif))
                .tracking(1.6)
                .foregroundStyle(palette.accent.opacity(0.8))
        }
        .padding(19)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.sidebar)
    }

    private func sidebarButton(
        _ title: String,
        symbol: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 11)
                .background(selected ? palette.selectedBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? palette.selectedText : palette.primaryText)
        .help(title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Template Manager")
                .font(.system(size: 39, weight: .regular, design: .serif))
                .foregroundStyle(palette.primaryText)
            Text("Choose a musical foundation for your next project.")
                .font(.system(size: 15, design: .serif))
                .italic()
                .foregroundStyle(palette.secondaryText)
            Rectangle()
                .fill(palette.accent.opacity(0.55))
                .frame(height: 1)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 26)
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(filters, id: \.self) { category in
                Button(category) { filter = category }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: filter == category ? .semibold : .regular))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(filter == category ? palette.selectedBackground : palette.surface,
                                in: Capsule())
                    .foregroundStyle(filter == category ? palette.selectedText : palette.primaryText)
            }
            Spacer(minLength: 10)
            TextField("Search templates", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Search templates")
        }
        .padding(.horizontal, 25)
        .padding(.top, 20)
        .padding(.bottom, 5)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Starter track layouts · choose your instruments after creating")
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Button("Cancel") { appState.dismissTemplateManager() }
                .keyboardShortcut(.cancelAction)
            Button("Create Project") { appState.createProject(using: selected) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Create a new \(selected.title) session")
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 17)
        .background(palette.panel)
    }
}

private struct TemplateSelectionCard: View {
    @Environment(\.studioPalette) private var palette
    let template: StudioProjectTemplate
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                art
                    .frame(height: 158)
                    .frame(maxWidth: .infinity)
                    .clipped()
                VStack(spacing: 8) {
                    Text(template.title)
                        .font(.system(size: 21, weight: .regular, design: .serif))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(template.subtitle.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(palette.surface)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? palette.accent : palette.separator,
                                  lineWidth: isSelected ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(palette.accent)
                        .padding(11)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.title + ", " + template.subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var art: some View {
        ZStack {
            LinearGradient(
                colors: [template.tint.opacity(0.95), palette.sidebar,
                         template.tint.opacity(0.67)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .strokeBorder(.white.opacity(0.12), lineWidth: 2)
                .frame(width: 180, height: 180)
                .offset(x: 85, y: -45)
            Circle()
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                .frame(width: 110, height: 110)
                .offset(x: -95, y: 55)
            Image(systemName: template.symbol)
                .font(.system(size: 66, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 9, y: 5)
        }
    }
}
