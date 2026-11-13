import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DAWCore
import DAWUI
import StudioIdentity

// MARK: - UTType Extension

extension UTType {
    static var dawProject: UTType {
        UTType(exportedAs: StudioApplicationIdentity.legacyProjectTypeIdentifier)
    }
}

// MARK: - Main App

@main
struct DAWApp: App {
    @StateObject private var appState = AppState()

    init() {
        // The development executable is named DAWApp for compatibility with
        // 'swift run DAWApp'; the visible product name is managed separately.
        ProcessInfo.processInfo.processName = StudioApplicationIdentity.displayName
        // The SwiftPM executable isn't a bundled .app; make it foreground-capable.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // Main document window
        WindowGroup(StudioApplicationIdentity.displayName) {
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
    @Published var projectID: UUID = UUID()  // Changes when project is loaded/created to force view refresh
    
    let recentProjectsManager = RecentProjectsManager()
    let autosaveManager = AutosaveManager()
    private let fileManager = ProjectFileManager()
    
    init() {
        self.currentProject = ProjectFactory.createNewProject()
        setupAutosave()
    }
    
    private func setupAutosave() {
        autosaveManager.configure { [weak self] in
            self?.currentProject ?? ProjectFactory.createNewProject()
        }
    }
    
    func updateProject(_ project: Project) {
        currentProject = project
        markUnsavedChanges()
    }
    
    func markUnsavedChanges() {
        hasUnsavedChanges = true
        autosaveManager.markUnsavedChanges()
        updateWindowTitle()
    }
    
    private func updateWindowTitle() {
        let name = currentProjectURL?.deletingPathExtension().lastPathComponent ?? currentProject.name
        windowTitle = hasUnsavedChanges ? "\(name) — Edited" : name
    }
    
    // MARK: - Project Management
    
    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dawProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true  // .dawproj is a package (directory)
        panel.treatsFilePackagesAsDirectories = false  // But show it as a file
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await self?.openProject(at: url)
            }
        }
    }
    
    func openProject(at url: URL) async {
        do {
            // Decode and validate the next project BEFORE tearing down the
            // current session. A missing/corrupt file must not silence the
            // existing instruments or stop its autosave.
            let loadedProject = try await fileManager.load(from: url)

            autosaveManager.stopAutosave()
            NotificationCenter.default.post(name: .clearAllPlugins, object: nil)

            // Allow the old graph to release its hosted instruments.
            try? await Task.sleep(nanoseconds: 100_000_000)

            currentProject = loadedProject
            currentProjectURL = url
            hasUnsavedChanges = false
            projectID = UUID()  // Force view refresh with new project
            recentProjectsManager.addRecentProject(url)
            autosaveManager.startAutosave(for: url)
            updateWindowTitle()
            
            // Give the view time to recreate, then restore plugin states
            try? await Task.sleep(nanoseconds: 500_000_000)
            NotificationCenter.default.post(name: .restorePluginStates, object: nil)
            
            print("[AppState] Opened project: \(url.path)")
        } catch {
            print("[AppState] Failed to open project: \(error)")
            // TODO: Show alert
        }
    }
    
    private var projectForSave: Project?
    private var saveCompletion: ((Project) -> Void)?
    
    /// Get the current project with all plugin states saved
    private func getProjectWithPluginStates() async -> Project {
        // Tell viewModel to save plugin states and return the project
        NotificationCenter.default.post(name: .savePluginStates, object: nil)
        
        // Small delay to let the states be saved
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Request the updated project
        var receivedProject: Project?
        let observer = NotificationCenter.default.addObserver(
            forName: .projectDataForSave,
            object: nil,
            queue: .main
        ) { notification in
            receivedProject = notification.object as? Project
        }
        
        NotificationCenter.default.post(name: .requestProjectForSave, object: nil)
        
        // Wait a bit for the response
        try? await Task.sleep(nanoseconds: 100_000_000)
        NotificationCenter.default.removeObserver(observer)
        
        return receivedProject ?? currentProject
    }
    
    func saveProject() {
        if let url = currentProjectURL {
            Task {
                do {
                    let projectToSave = await getProjectWithPluginStates()
                    try await fileManager.saveQuick(project: projectToSave, to: url)
                    await MainActor.run {
                        hasUnsavedChanges = false
                        updateWindowTitle()
                    }
                    print("[AppState] Saved project: \(url.path)")
                } catch {
                    print("[AppState] Failed to save: \(error)")
                }
            }
        } else {
            saveProjectAs()
        }
    }
    
    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.dawProject]
        panel.nameFieldStringValue = currentProject.name
        
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            
            Task {
                do {
                    // Get project with plugin states
                    let projectToSave = await self.getProjectWithPluginStates()
                    
                    try await self.fileManager.save(project: projectToSave, to: url)
                    await MainActor.run {
                        // Update URL - ensure it has correct extension
                        var finalURL = url
                        if finalURL.pathExtension != ProjectFileManager.projectExtension {
                            finalURL = url.deletingPathExtension().appendingPathExtension(ProjectFileManager.projectExtension)
                        }
                        self.currentProjectURL = finalURL
                        self.currentProject = projectToSave  // Sync with saved version
                        self.hasUnsavedChanges = false
                        self.recentProjectsManager.addRecentProject(finalURL)
                        self.autosaveManager.startAutosave(for: finalURL)
                        self.updateWindowTitle()
                    }
                    print("[AppState] Saved project as: \(url.path)")
                } catch {
                    print("[AppState] Failed to save project: \(error)")
                }
            }
        }
    }
    
    func newProject() {
        // TODO: Prompt to save if needed
        autosaveManager.stopAutosave()
        
        // Clear all existing plugins first
        NotificationCenter.default.post(name: .clearAllPlugins, object: nil)
        
        currentProject = ProjectFactory.createNewProject()
        currentProjectURL = nil
        hasUnsavedChanges = false
        projectID = UUID()  // Force view refresh
        updateWindowTitle()
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
                Text("\(StudioApplicationIdentity.displayName) Appearance").font(.title3.bold())
                Text("Choose a visual style for your composing workspace.")
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
