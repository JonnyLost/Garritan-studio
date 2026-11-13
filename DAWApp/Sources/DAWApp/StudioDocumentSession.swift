import AppKit
import Foundation
import SwiftUI
import DAWCore

/// Native Studio document controller, independent of the inherited app's
/// login and AI features. All mutable session state is confined to MainActor.
/// File operations share one ProjectFileManager actor with autosave.
@MainActor
final class AppState: ObservableObject {
    @Published var currentProject: Project
    @Published var currentProjectURL: URL?
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var windowTitle: String
    @Published private(set) var projectID = UUID()
    @Published var projectErrorMessage: String?

    let recentProjectsManager = RecentProjectsManager()
    let autosaveManager: AutosaveManager
    private let fileManager: ProjectFileManager
    private var revision = StudioSessionRevision()
    private var isTransitioning = false
    private var isSaving = false
    private var pendingPluginRestoreID: UUID?

    init() {
        let fileManager = ProjectFileManager()
        self.fileManager = fileManager
        self.autosaveManager = AutosaveManager(fileManager: fileManager)
        let initial = ProjectFactory.createNewProject()
        self.currentProject = initial
        self.windowTitle = initial.name

        autosaveManager.configure(
            snapshotProvider: { [weak self] in
                guard let self else { return nil }
                return self.captureProjectSnapshot()
            },
            onSaved: { [weak self] url, ticket in
                self?.acceptSave(ticket, for: url)
            }
        )
    }

    /// Reject notifications from a previously destroyed project window.
    func updateProject(_ project: Project) {
        guard project.id == currentProject.id else { return }
        currentProject = project
        markUnsavedChanges()
    }

    func markUnsavedChanges() {
        revision.markEdited()
        hasUnsavedChanges = revision.hasUnsavedChanges
        autosaveManager.markUnsavedChanges()
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let name = currentProjectURL?.deletingPathExtension().lastPathComponent
            ?? currentProject.name
        windowTitle = hasUnsavedChanges ? "\(name) — Edited" : name
    }

    /// Pull the live view model's plug-in state and DAW layout synchronously.
    /// NotificationCenter posts immediately to the active MainWindowView.
    /// The save ticket is taken AFTER the capture, so any mutations caused by
    /// collecting AU state are included in the saved revision.
    private func captureProjectSnapshot() -> StudioAutosaveSnapshot {
        NotificationCenter.default.post(name: .savePluginStates, object: nil)

        final class CaptureBox {
            var project: Project?
        }
        let box = CaptureBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .projectDataForSave, object: nil, queue: nil
        ) { notification in
            box.project = notification.object as? Project
        }
        NotificationCenter.default.post(name: .requestProjectForSave, object: nil)
        NotificationCenter.default.removeObserver(observer)

        let project = box.project ?? currentProject
        return StudioAutosaveSnapshot(project: project, ticket: revision.saveTicket())
    }

    private func acceptSave(_ ticket: StudioSessionSaveTicket, for url: URL) {
        guard currentProjectURL == url,
              ticket.sessionID == revision.sessionID else { return }
        let isClean = revision.markSaved(ticket)
        hasUnsavedChanges = revision.hasUnsavedChanges
        if isClean {
            autosaveManager.acknowledgeManualSave()
        }
        updateWindowTitle()
    }

    /// Only one explicit save or document transition may run at a time.
    /// A successful save of an earlier revision never clears later edits.
    @discardableResult
    private func persistCurrentProject(saveAs: Bool = false) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let proposedURL: URL
        if !saveAs, let currentProjectURL {
            proposedURL = currentProjectURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.dawProject]
            panel.nameFieldStringValue = currentProject.name
            let selectedURL: URL? = await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
            guard let selectedURL else { return false }
            proposedURL = selectedURL
        }

        let destination = ProjectFileManager.normalizedProjectURL(proposedURL)
        let snapshot = captureProjectSnapshot()

        do {
            try await fileManager.save(project: snapshot.project, to: destination)
            guard snapshot.ticket.sessionID == revision.sessionID else {
                // Session changed while I/O was running; do not attach an old
                // project's save receipt to the new document.
                return false
            }
            let previousURL = currentProjectURL
            currentProjectURL = destination
            if previousURL != destination {
                autosaveManager.startAutosave(for: destination)
            }
            acceptSave(snapshot.ticket, for: destination)
            if hasUnsavedChanges {
                autosaveManager.markUnsavedChanges()
            }
            recentProjectsManager.addRecentProject(destination)
            print("[StudioSession] Saved project: \(destination.path)")
            return true
        } catch {
            projectErrorMessage = "Couldn't save \(destination.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    func saveProject() {
        guard !isTransitioning else { return }
        Task { await persistCurrentProject() }
    }

    func saveProjectAs() {
        guard !isTransitioning else { return }
        Task { await persistCurrentProject(saveAs: true) }
    }

    /// Discarding an edited document always requires an explicit choice.
    /// If Save fails or the Save As panel is cancelled, keep the old session.
    private func confirmReplaceEditedSession() async -> Bool {
        guard revision.hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(currentProject.name)?"
        alert.informativeText = "Opening or creating another project will replace the current session."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard await persistCurrentProject() else { return false }
            // Edits made during the save must not be discarded accidentally.
            return !revision.hasUnsavedChanges
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func openProject() {
        guard !isTransitioning, !isSaving else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dawProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.openProject(at: url)
            }
        }
    }

    func openProject(at url: URL) async {
        guard !isTransitioning, !isSaving else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        guard await confirmReplaceEditedSession() else { return }
        let beforeLoad = revision.saveTicket()
        do {
            // Never clear a live graph until the incoming project fully decodes.
            let loadedProject = try await fileManager.load(from: url)
            guard beforeLoad == revision.saveTicket() else {
                projectErrorMessage = "The current session changed while opening a file. Try opening it again."
                return
            }

            autosaveManager.stopAutosave()
            NotificationCenter.default.post(name: .clearAllPlugins, object: nil)

            revision.replaceSession()
            currentProject = loadedProject
            currentProjectURL = url.standardizedFileURL
            hasUnsavedChanges = false
            projectID = UUID()
            pendingPluginRestoreID = loadedProject.id
            recentProjectsManager.addRecentProject(url)
            autosaveManager.startAutosave(for: url)
            updateWindowTitle()
            print("[StudioSession] Opened project: \(url.path)")
            // Instrument restoration is triggered when the new view's audio
            // engine reports ready, not after an arbitrary sleep.
        } catch {
            projectErrorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func restorePluginsIfReady(for readyProjectID: UUID) {
        guard pendingPluginRestoreID == readyProjectID,
              currentProject.id == readyProjectID else { return }
        pendingPluginRestoreID = nil
        NotificationCenter.default.post(name: .restorePluginStates, object: nil)
    }

    func newProject() {
        guard !isTransitioning, !isSaving else { return }
        Task { await startNewProject() }
    }

    private func startNewProject() async {
        guard !isTransitioning, !isSaving else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        guard await confirmReplaceEditedSession() else { return }

        autosaveManager.stopAutosave()
        NotificationCenter.default.post(name: .clearAllPlugins, object: nil)
        revision.replaceSession()
        currentProject = ProjectFactory.createNewProject()
        currentProjectURL = nil
        hasUnsavedChanges = false
        pendingPluginRestoreID = nil
        projectID = UUID()
        updateWindowTitle()
    }
}
