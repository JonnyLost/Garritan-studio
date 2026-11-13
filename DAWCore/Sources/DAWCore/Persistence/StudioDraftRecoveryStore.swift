import Foundation

/// A recoverable local draft, separate from the user's chosen project file.
public struct StudioRecoveryDraft: Identifiable, Sendable {
    public let id: UUID
    public let projectName: String
    public let fileURL: URL
    public let modifiedAt: Date

    public init(id: UUID, projectName: String, fileURL: URL, modifiedAt: Date) {
        self.id = id
        self.projectName = projectName
        self.fileURL = fileURL
        self.modifiedAt = modifiedAt
    }
}

/// Crash-recovery packages are real .dawproj packages, saved through Studio's
/// existing transactional persistence. This preserves referenced audio and AU
/// state without inventing a second serialization schema.
///
/// Drafts are never inserted into Open Recent, never used as the user's project
/// URL, and never deleted until an explicit discard or a confirmed Save.
public actor StudioDraftRecoveryStore {
    private let rootDirectory: URL
    private let fileManager: ProjectFileManager
    private var savingSessionIDs = Set<UUID>()

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Studio/Recovery", isDirectory: true)
    }

    public init(directory: URL = StudioDraftRecoveryStore.defaultDirectory(),
                fileManager: ProjectFileManager = ProjectFileManager()) {
        rootDirectory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func draftURL(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            sessionID.uuidString, isDirectory: false
        ).appendingPathExtension(ProjectFileManager.projectExtension)
    }

    /// Return false if an earlier snapshot is still being written. The caller
    /// should schedule another snapshot after its current write completes.
    @discardableResult
    public func store(project: Project, sessionID: UUID) async throws -> Bool {
        guard !savingSessionIDs.contains(sessionID) else { return false }
        savingSessionIDs.insert(sessionID)
        defer { savingSessionIDs.remove(sessionID) }

        try FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true
        )
        try await fileManager.save(project: project, to: draftURL(for: sessionID))
        return true
    }

    /// Corrupt/unreadable drafts are left untouched for manual recovery.
    public func availableDrafts() async -> [StudioRecoveryDraft] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return [] }

        var drafts: [StudioRecoveryDraft] = []
        for url in entries {
            guard url.pathExtension.lowercased() == ProjectFileManager.projectExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let metadata = try? await fileManager.loadMetadata(from: url)
            else { continue }
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? metadata.modifiedAt
            drafts.append(StudioRecoveryDraft(
                id: id, projectName: metadata.name,
                fileURL: url, modifiedAt: date
            ))
        }
        return drafts.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func load(_ draft: StudioRecoveryDraft) async throws -> Project {
        guard draft.fileURL.standardizedFileURL == draftURL(for: draft.id) else {
            throw PersistenceError.invalidFormat("Recovery draft path mismatch")
        }
        return try await fileManager.load(from: draft.fileURL)
    }

    public func discard(sessionID: UUID) throws {
        guard !savingSessionIDs.contains(sessionID) else {
            throw PersistenceError.invalidFormat("Recovery snapshot is still being written")
        }
        let url = draftURL(for: sessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
