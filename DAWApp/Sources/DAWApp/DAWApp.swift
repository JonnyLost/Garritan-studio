import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DAWCore
import DAWUI

// MARK: - UTType Extension

extension UTType {
    static var dawProject: UTType {
        UTType(exportedAs: "com.musio.create.project")
    }
}

// MARK: - Main App

@main
struct DAWApp: App {
    @StateObject private var appState = AppState()

    init() {
        // The development executable is named DAWApp for compatibility with
        // 'swift run DAWApp', but the visible product is Garritan Studio.
        ProcessInfo.processInfo.processName = "Garritan Studio"
        // The SwiftPM executable isn't a bundled .app; make it foreground-capable.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // Main document window
        WindowGroup("Garritan Studio") {
            StudioAppearanceHost {
                MainWindowView(project: appState.currentProject)
                .onAppear {
                    DispatchQueue.main.async {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                .environmentObject(appState)
                .id(appState.projectID)  // Force view recreation when project changes
                .onReceive(NotificationCenter.default.publisher(for: .projectDidChange)) { notification in
                    // Sync project from viewModel back to appState
                    if let project = notification.object as? Project {
                        appState.currentProject = project
                    }
                    appState.markUnsavedChanges()
                }
            }
        }
        .commands {
            // File commands
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    appState.newProject()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            CommandGroup(after: .newItem) {
                Button("Open...") {
                    appState.openProject()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Menu("Open Recent") {
                    ForEach(appState.recentProjectsManager.recentProjects) { project in
                        Button(project.name) {
                            Task {
                                await appState.openProject(at: project.fileURL)
                            }
                        }
                    }
                    
                    if !appState.recentProjectsManager.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Recent") {
                            appState.recentProjectsManager.clearRecentProjects()
                        }
                    }
                }
                
                Divider()
                
                Button("Save") {
                    appState.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                
                Button("Save As...") {
                    appState.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            
            // Edit commands
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .performUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo") {
                    NotificationCenter.default.post(name: .performRedo, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            
            // Transport commands
            CommandMenu("Transport") {
                Button("Play/Pause") {
                    NotificationCenter.default.post(name: .togglePlayPause, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("Stop") {
                    NotificationCenter.default.post(name: .stop, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                
                Button("Return to Zero") {
                    NotificationCenter.default.post(name: .returnToZero, object: nil)
                }
                .keyboardShortcut(.home, modifiers: [])
                
                Divider()
                
                Button("Toggle Loop") {
                    NotificationCenter.default.post(name: .toggleLoop, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                
                Button("Toggle Metronome") {
                    NotificationCenter.default.post(name: .toggleMetronome, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            
            // Track commands
            CommandMenu("Track") {
                Button("New Audio Track") {
                    NotificationCenter.default.post(name: .newAudioTrack, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                
                Button("New MIDI Track") {
                    NotificationCenter.default.post(name: .newMIDITrack, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Delete Selected Track") {
                    NotificationCenter.default.post(name: .deleteSelectedTrack, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            
            // View commands
            CommandGroup(after: .toolbar) {
                Button("Toggle Mixer") {
                    NotificationCenter.default.post(name: .toggleMixer, object: nil)
                }
                .keyboardShortcut("m", modifiers: .command)
                
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                
                Button("Show/Hide On-Screen Keyboard") {
                    NotificationCenter.default.post(name: Notification.Name("toggleStudioKeyboard"), object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()
                
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
                
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
        
        // Settings window
        Settings {
            StudioAppearanceHost {
                SettingsView()
            }
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var currentProject: Project
    @Published var currentProjectURL: URL?
    @Published var hasUnsavedChanges: Bool = false
    @Published var windowTitle: String = "Untitled Project"
    @Published var projectID: UUID = UUID()

    let recentProjectsManager = RecentProjectsManager()
    let autosaveManager = AutosaveManager()
    private let fileManager = ProjectFileManager()
    private var saveRevision = ProjectSaveRevision()
    private var isSaveInProgress = false
    private var isSavePanelOpen = false
    private var isOpeningProject = false

    private enum DocumentError: LocalizedError {
        case snapshotUnavailable
        case sessionChanged

        var errorDescription: String? {
            switch self {
            case .snapshotUnavailable:
                return "Studio could not capture the current instruments and project state. The project was not saved; please try again."
            case .sessionChanged:
                return "The project changed during saving. The current document was not marked as saved."
            }
        }
    }

    init() {
        currentProject = ProjectFactory.createNewProject()
        autosaveManager.configure(saveHandler: { [weak self] in
            guard let self, let url = self.currentProjectURL else { return false }
            return await self.persistProject(to: url, asNewDocument: false, showErrors: false)
        })
    }

    func updateProject(_ project: Project) {
        currentProject = project
        markUnsavedChanges()
    }

    func markUnsavedChanges() {
        saveRevision.markChanged()
        hasUnsavedChanges = saveRevision.hasUnsavedChanges
        autosaveManager.markUnsavedChanges()
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let name = currentProjectURL?.deletingPathExtension().lastPathComponent
            ?? currentProject.name
        windowTitle = hasUnsavedChanges ? "\(name) — Edited" : name
    }

    // MARK: - Document loading

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dawProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.openProject(at: url) }
        }
    }

    func openProject(at url: URL) async {
        guard !isSaveInProgress, !isSavePanelOpen, !isOpeningProject else { return }
        isOpeningProject = true
        defer { isOpeningProject = false }

        do {
            // Check the incoming file before asking to discard or save the
            // existing session. Corrupt projects must not close a healthy one.
            let loadedProject = try await fileManager.load(from: url)
            guard await confirmCanReplaceCurrentProject() else { return }

            autosaveManager.stopAutosave()
            NotificationCenter.default.post(name: .clearAllPlugins, object: nil)

            // Existing project UI and Audio Unit graph are rebuilt after swap.
            try? await Task.sleep(nanoseconds: 100_000_000)
            currentProject = loadedProject
            currentProjectURL = url
            projectID = UUID()
            resetDocumentRevision()
            recentProjectsManager.addRecentProject(url)
            autosaveManager.startAutosave(for: url)
            updateWindowTitle()

            try? await Task.sleep(nanoseconds: 500_000_000)
            NotificationCenter.default.post(name: .restorePluginStates, object: nil)
            print("[AppState] Opened project: \(url.path)")
        } catch {
            print("[AppState] Failed to open project: \(error)")
            presentError("Unable to Open Project", error: error)
        }
    }

    // MARK: - Save coordination

    /// Notifications from the active MainWindowView are synchronous on the
    /// main thread. A missing response is an error, not permission to save
    /// stale AppState data or omit an edited Audio Unit preset.
    private func captureProjectWithPluginStates() throws -> Project {
        let expectedProjectID = currentProject.id
        var snapshot: Project?
        let observer = NotificationCenter.default.addObserver(
            forName: .projectDataForSave, object: nil, queue: nil
        ) { notification in
            guard let received = notification.object as? Project,
                  received.id == expectedProjectID else { return }
            snapshot = received
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(name: .captureProjectForSave, object: nil)
        guard let snapshot else { throw DocumentError.snapshotUnavailable }
        return snapshot
    }

    @discardableResult
    private func persistProject(
        to url: URL, asNewDocument: Bool, showErrors: Bool
    ) async -> Bool {
        guard !isSaveInProgress else { return false }
        isSaveInProgress = true
        defer { isSaveInProgress = false }

        do {
            // Snapshot and revision must be captured together *after* saving
            // plugin state has synchronized the live view model.
            let snapshot = try captureProjectWithPluginStates()
            let snapshotRevision = saveRevision.capture()
            let sessionID = projectID

            if asNewDocument {
                try await fileManager.save(project: snapshot, to: url)
            } else {
                try await fileManager.saveQuick(project: snapshot, to: url)
            }

            guard sessionID == projectID else { throw DocumentError.sessionChanged }

            var finalURL = url
            if finalURL.pathExtension != ProjectFileManager.projectExtension {
                finalURL = url.deletingPathExtension()
                    .appendingPathExtension(ProjectFileManager.projectExtension)
            }
            if asNewDocument {
                currentProjectURL = finalURL
                recentProjectsManager.addRecentProject(finalURL)
                autosaveManager.startAutosave(for: finalURL)
            }

            // Never replace currentProject with an old pre-save snapshot.
            // If the user continued editing while files were copied, those
            // changes remain in memory and the title stays "Edited".
            if saveRevision.acknowledgeSave(snapshot: snapshotRevision) {
                hasUnsavedChanges = false
                autosaveManager.markSaved()
            } else {
                hasUnsavedChanges = true
                autosaveManager.markUnsavedChanges()
            }
            updateWindowTitle()
            print("[AppState] Saved project: \(finalURL.path)")
            return true
        } catch {
            print("[AppState] Project save failed: \(error)")
            if showErrors { presentError("Unable to Save Project", error: error) }
            return false
        }
    }

    func saveProject() {
        Task { _ = await saveToCurrentLocationOrPrompt() }
    }

    func saveProjectAs() {
        Task {
            guard let url = await chooseSaveLocation() else { return }
            _ = await persistProject(to: url, asNewDocument: true, showErrors: true)
        }
    }

    @discardableResult
    private func saveToCurrentLocationOrPrompt() async -> Bool {
        if let url = currentProjectURL {
            return await persistProject(to: url, asNewDocument: false, showErrors: true)
        }
        guard let url = await chooseSaveLocation() else { return false }
        return await persistProject(to: url, asNewDocument: true, showErrors: true)
    }

    private func chooseSaveLocation() async -> URL? {
        guard !isSaveInProgress, !isSavePanelOpen else { return nil }
        isSavePanelOpen = true
        defer { isSavePanelOpen = false }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.dawProject]
        panel.nameFieldStringValue = currentProject.name
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Protect both New and Open Recent against replacing an edited project.
    /// Saving must finish successfully before the old instrument graph is torn
    /// down. Cancel leaves the entire session unchanged.
    private func confirmCanReplaceCurrentProject() async -> Bool {
        guard !isSaveInProgress, !isSavePanelOpen else { return false }
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(currentProject.name)?"
        alert.informativeText = "Changes will be lost if you replace this project without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            return await saveToCurrentLocationOrPrompt()
        }
        return response == .alertThirdButtonReturn
    }

    func newProject() {
        Task {
            guard !isOpeningProject,
                  await confirmCanReplaceCurrentProject() else { return }

            autosaveManager.stopAutosave()
            NotificationCenter.default.post(name: .clearAllPlugins, object: nil)
            currentProject = ProjectFactory.createNewProject()
            currentProjectURL = nil
            projectID = UUID()
            resetDocumentRevision()
            updateWindowTitle()
        }
    }

    private func resetDocumentRevision() {
        saveRevision.resetForNewSession()
        hasUnsavedChanges = false
        autosaveManager.markSaved()
    }

    private func presentError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Notification for Project Changes

extension Notification.Name {
    static let projectDidChange = Notification.Name("projectDidChange")
}

// Notification names are defined in DAWUI/Views/Shared/KeyboardShortcuts.swift

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 680, height: 540)
    }
}

/// Appearance is a user preference, not a property of the musical project.
private struct AppearanceSettingsView: View {
    @State private var showingIconGallery = false
    @AppStorage("garritanStudio.appearance") private var selection = StudioAppearance.system.rawValue
    @AppStorage("garritanStudio.iconCollection") private var iconSelection = StudioIconCollection.matchAppearance.rawValue
    @Environment(\.studioPalette) private var palette
    @Environment(\.studioIconCollection) private var resolvedIcons

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Garritan Studio Appearance").font(.title3.bold())
                Text("Three visual styles inspired by Garritan's orchestral heritage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ForEach(StudioAppearance.visualThemes) { appearance in
                    Button {
                        selection = appearance.rawValue
                    } label: {
                        themeCard(appearance)
                    }
                    .buttonStyle(.plain)
                    .help(appearance.subtitle)
                }
            }
            Toggle("Automatically follow macOS light and dark appearance", isOn: Binding(
                get: { selection == StudioAppearance.system.rawValue },
                set: { selection = $0 ? StudioAppearance.system.rawValue : StudioAppearance.gpo5Modern.rawValue }
            ))
            Text("When automatic, light uses Personal Orchestra and dark uses Orchestral Strings. The chosen theme is saved for future launches.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instrument Icons").font(.headline)
                    Text("Choose a full icon collection, or match your selected appearance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Icon Collection", selection: $iconSelection) {
                    ForEach(StudioIconCollection.allCases) { icons in
                        Text(icons.title).tag(icons.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 202)
            }

            HStack(spacing: 11) {
                ForEach(["Piccolo", "Oboe Solo", "French Horn 1 Solo",
                         "Trumpet 1 Solo", "Violin 1 KS", "Cello 1 KS",
                         "Timpani", "Concert Grand Harp"], id: \.self) { name in
                    VStack(spacing: 7) {
                        StudioInstrumentIcon(name: name, size: 43)
                        Text(name.components(separatedBy: " ").first ?? name)
                            .font(.system(size: 9))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text((StudioIconCollection(rawValue: iconSelection) ?? .matchAppearance).detail +
                     " · Active: " + resolvedIcons.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingIconGallery = true
                } label: {
                    Label("View All Instrument Icons", systemImage: "square.grid.3x3")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .sheet(isPresented: $showingIconGallery) {
            StudioIconGalleryView()
        }
    }

    private func themeCard(_ appearance: StudioAppearance) -> some View {
        let colors = StudioPalette(appearance: appearance)
        let selected = selection == appearance.rawValue

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Spacer()
                Image(systemName: "music.note")
            }
            .font(.caption)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(colors.sidebar)
                    .frame(width: 22, height: 66)
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colors.surface)
                        .frame(height: 27)
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colors.accentMuted)
                                .frame(height: 29)
                        }
                    }
                }
            }
            Text(appearance.title)
                .font(.caption.bold())
                .lineLimit(1)
            Text(appearance == .heritageLight ? "Heritage Light" :
                 appearance == .gpo5Modern ? "Modern" : "Heritage Dark")
                .font(.caption2)
                .opacity(0.8)
        }
        .foregroundStyle(colors.primaryText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(colors.canvas))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? colors.accent : colors.separator,
                              lineWidth: selected ? 3 : 1)
        }
    }
}

struct GeneralSettingsView: View {
    @State private var autosaveInterval = 60
    @State private var showWelcomeScreen = true
    
    var body: some View {
        Form {
            Section("Autosave") {
                Toggle("Enable Autosave", isOn: .constant(true))
                
                Picker("Autosave Interval", selection: $autosaveInterval) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
            }
            
            Section("Startup") {
                Toggle("Show Welcome Screen", isOn: $showWelcomeScreen)
            }
        }
        .padding()
    }
}
