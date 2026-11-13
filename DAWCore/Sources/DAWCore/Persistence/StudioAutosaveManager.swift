import Foundation
import Combine

/// Captured with its session revision, before asynchronous file I/O starts.
public struct StudioAutosaveSnapshot: Sendable {
    public let project: Project
    public let ticket: StudioSessionSaveTicket

    public init(project: Project, ticket: StudioSessionSaveTicket) {
        self.project = project
        self.ticket = ticket
    }
}

/// The autosave scheduler is UI/session-owned; disk writes share the exact
/// ProjectFileManager actor used by manual Save and Save As.
///
/// A generation token ensures an old session's in-flight autosave does not
/// mark a newly opened document clean. Revision checks preserve edits made
/// while the file write was pending.
@MainActor
public final class AutosaveManager: ObservableObject {
    private var autosaveTimer: Timer?
    private let fileManager: ProjectFileManager
    private var snapshotProvider: (@MainActor () async -> StudioAutosaveSnapshot?)?
    private var onSaved: (@MainActor (URL, StudioSessionSaveTicket) -> Void)?
    private var projectURL: URL?
    private var generation = UUID()
    private var editRevision: UInt64 = 0
    private var isSaving = false

    @Published public private(set) var lastAutosaveDate: Date?
    @Published public private(set) var hasUnsavedChanges = false

    public var autosaveInterval: TimeInterval = 60

    public init(fileManager: ProjectFileManager = ProjectFileManager()) {
        self.fileManager = fileManager
    }

    public func configure(
        snapshotProvider: @escaping @MainActor () async -> StudioAutosaveSnapshot?,
        onSaved: @escaping @MainActor (URL, StudioSessionSaveTicket) -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        self.onSaved = onSaved
    }

    public func startAutosave(for url: URL) {
        stopAutosave()
        projectURL = ProjectFileManager.normalizedProjectURL(url)
        hasUnsavedChanges = false
        lastAutosaveDate = nil
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: autosaveInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.saveIfNeeded()
            }
        }
    }

    public func stopAutosave() {
        generation = UUID()
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        projectURL = nil
        hasUnsavedChanges = false
    }

    public func markUnsavedChanges() {
        editRevision &+= 1
        hasUnsavedChanges = true
    }

    /// Called only when a manual save is confirmed current and no newer
    /// document edits are outstanding.
    public func acknowledgeManualSave() {
        hasUnsavedChanges = false
    }

    /// Also callable on application lifecycle events and by unit tests.
    public func saveIfNeeded() async {
        guard !isSaving, hasUnsavedChanges,
              let url = projectURL, let snapshotProvider else { return }

        isSaving = true
        defer { isSaving = false }
        let originalGeneration = generation
        // Capture the dirty revision BEFORE the potentially suspending
        // snapshot request. A later edit must survive this autosave, even if
        // it occurs before file I/O begins.
        let savedEditRevision = editRevision

        guard let snapshot = await snapshotProvider(),
              originalGeneration == generation,
              projectURL == url else { return }

        do {
            try await fileManager.saveQuick(project: snapshot.project, to: url)
            guard originalGeneration == generation,
                  projectURL == url else { return }
            lastAutosaveDate = Date()
            if editRevision == savedEditRevision {
                hasUnsavedChanges = false
            }
            onSaved?(url, snapshot.ticket)
        } catch {
            // Preserve the dirty marker and the last good project package.
            print("[Autosave] Failed to save \(url.lastPathComponent): \(error)")
        }
    }
}
