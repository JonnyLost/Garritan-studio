import AppKit
import Foundation
import SwiftUI
import DAWCore
import DAWUI

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

    let snapshotBridge = StudioProjectSnapshotBridge()
    let recentProjectsManager = RecentProjectsManager()
    let autosaveManager: AutosaveManager
    private let fileManager: ProjectFileManager
    private let recoveryStore: StudioDraftRecoveryStore
    private var revision = StudioSessionRevision()
    private var recoveryTask: Task<Void, Never>?
    private var activeRecoveryID: UUID?
    private var hasCheckedRecoveryOnLaunch = false
    private var hasReportedRecoveryError = false
    private var isTransitioning = false
    private var isSaving = false
    private var isCapturingSnapshot = false
    private var pendingPluginRestoreID: UUID?

    /// Include in-flight operations even if the last saved revision currently
    /// matches the edited revision. Closing mid-write can still lose data.
    var needsExitNegotiation: Bool {
        hasUnsavedChanges || isSaving || isTransitioning
    }

    init() {
        let fileManager = ProjectFileManager()
        self.fileManager = fileManager
        self.autosaveManager = AutosaveManager(fileManager: fileManager)
        self.recoveryStore = StudioDraftRecoveryStore(fileManager: fileManager)
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
        // Reading AU state and DAW layout can mutate the value-type project.
        // This is a save snapshot, not a fresh user edit.
        guard !isCapturingSnapshot else { return }
        markUnsavedChanges()
    }

    func markUnsavedChanges() {
        revision.markEdited()
        hasUnsavedChanges = revision.hasUnsavedChanges
        autosaveManager.markUnsavedChanges()
        updateWindowTitle()
        scheduleUntitledRecovery()
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
        isCapturingSnapshot = true
        defer { isCapturingSnapshot = false }
        NotificationCenter.default.post(name: .savePluginStates, object: nil)

        // Plugin state gathering still notifies the composing view; the
        // document snapshot itself is now a typed project-scoped callback.
        let project = snapshotBridge.snapshot(for: currentProject.id) ?? currentProject
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
        // Manual Save must never race an older in-flight autosave into the
        // same .dawproj; the hold ends on success, error, or cancellation.
        await autosaveManager.beginManualSave()
        defer { autosaveManager.endManualSave() }
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
            if !hasUnsavedChanges {
                await discardActiveRecovery()
            }
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
        panel.allowedContentTypes = [.dawProject, .json]
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

            await discardActiveRecovery()
            autosaveManager.stopAutosave()
            snapshotBridge.clearPlugins(for: currentProject.id)

            revision.replaceSession()
            currentProject = loadedProject
            // Legacy single-JSON files remain readable, but are not quietly
            // overwritten or converted during autosave. Save asks for .dawproj.
            let isPackage = url.pathExtension.lowercased() == ProjectFileManager.projectExtension
            currentProjectURL = isPackage ? url.standardizedFileURL : nil
            if !isPackage {
                revision.markEdited()
                scheduleUntitledRecovery()
            }
            hasUnsavedChanges = revision.hasUnsavedChanges
            projectID = UUID()
            pendingPluginRestoreID = loadedProject.id
            recentProjectsManager.addRecentProject(url)
            if let currentProjectURL {
                autosaveManager.startAutosave(for: currentProjectURL)
            }
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
        snapshotBridge.restorePlugins(for: readyProjectID)
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

        await discardActiveRecovery()
        autosaveManager.stopAutosave()
        snapshotBridge.clearPlugins(for: currentProject.id)
        revision.replaceSession()
        currentProject = ProjectFactory.createNewProject()
        currentProjectURL = nil
        hasUnsavedChanges = false
        pendingPluginRestoreID = nil
        projectID = UUID()
        updateWindowTitle()
    }
}

    
// MARK: - Untitled session crash recovery

extension AppState {
    /// Coalesce edits before writing the project and its actual audio files
    /// to the private Studio/Recovery directory.
    private func scheduleUntitledRecovery() {
        guard currentProjectURL == nil, revision.hasUnsavedChanges else { return }
        if activeRecoveryID == nil { activeRecoveryID = revision.sessionID }
        recoveryTask?.cancel()
        let expectedSession = revision.sessionID
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch { return }
            await self?.storeUntitledRecovery(expectedSession: expectedSession)
        }
    }

    private func storeUntitledRecovery(expectedSession: UUID) async {
        guard !Task.isCancelled,
              revision.sessionID == expectedSession,
              currentProjectURL == nil, revision.hasUnsavedChanges,
              let recoveryID = activeRecoveryID else { return }
        let snapshot = captureProjectSnapshot()
        guard snapshot.ticket.sessionID == expectedSession else { return }

        do {
            let stored = try await recoveryStore.store(
                project: snapshot.project, sessionID: recoveryID
            )
            guard revision.sessionID == expectedSession,
                  currentProjectURL == nil else { return }
            if !stored || revision.saveTicket() != snapshot.ticket {
                scheduleUntitledRecovery()
            }
        } catch {
            print("[StudioRecovery] Untitled draft save failed: \(error)")
            if !hasReportedRecoveryError {
                hasReportedRecoveryError = true
                projectErrorMessage = "Couldn't create an emergency recovery copy: \(error.localizedDescription). Please save your project to a chosen folder."
            }
        }
    }

    private func discardActiveRecovery() async {
        let previous = recoveryTask
        recoveryTask?.cancel()
        recoveryTask = nil
        await previous?.value
        if let recoveryID = activeRecoveryID {
            do {
                try await recoveryStore.discard(sessionID: recoveryID)
            } catch {
                print("[StudioRecovery] Unable to discard backup: \(error)")
            }
        }
        activeRecoveryID = nil
        hasReportedRecoveryError = false
    }

    /// Offer the newest intact draft once per app launch; never remove a
    /// recovery project without the user's explicit choice or successful Save.
    func offerRecoveryOnLaunch() {
        guard !hasCheckedRecoveryOnLaunch else { return }
        hasCheckedRecoveryOnLaunch = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let drafts = await recoveryStore.availableDrafts()
            guard let draft = drafts.first,
                  currentProjectURL == nil, !revision.hasUnsavedChanges else { return }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Recover an unfinished Studio project?"
            alert.informativeText = "\(draft.projectName) has a recovery copy from \(draft.modifiedAt.formatted()). Restore it, leave it for later, or discard the copy."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Discard Copy")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    let before = revision.saveTicket()
                    let recovered = try await recoveryStore.load(draft)
                    guard before == revision.saveTicket(),
                          currentProjectURL == nil else { return }
                    autosaveManager.stopAutosave()
                    snapshotBridge.clearPlugins(for: currentProject.id)
                    revision.replaceSession()
                    currentProject = recovered
                    currentProjectURL = nil
                    projectID = UUID()
                    pendingPluginRestoreID = recovered.id
                    activeRecoveryID = draft.id
                    revision.markEdited()
                    hasUnsavedChanges = true
                    updateWindowTitle()
                    scheduleUntitledRecovery()
                } catch {
                    projectErrorMessage = "Recovery failed: \(error.localizedDescription). The original recovery package was kept."
                }
            case .alertThirdButtonReturn:
                do {
                    try await recoveryStore.discard(sessionID: draft.id)
                } catch {
                    projectErrorMessage = "Couldn't discard the recovery copy: \(error.localizedDescription)"
                }
            default:
                break
            }
        }
    }

    /// Try a fresh recovery snapshot when Studio leaves the foreground.
    func preserveUntitledWhenInactive() {
        guard currentProjectURL == nil, revision.hasUnsavedChanges else { return }
        recoveryTask?.cancel()
        let expected = revision.sessionID
        recoveryTask = Task { @MainActor [weak self] in
            await self?.storeUntitledRecovery(expectedSession: expected)
        }
    }

    /// The application delegate calls this before authorizing a macOS quit.
    /// Cancel/failed Save always means the app must stay open.
    func confirmApplicationTermination() async -> Bool {
        guard !isTransitioning, !isSaving else { return false }
        guard await confirmReplaceEditedSession() else { return false }
        await discardActiveRecovery()
        return true
    }
}
