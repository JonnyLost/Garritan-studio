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

        // Include the canonical name of any hidden completed backup.
        // ProjectFileManager.loadMetadata can restore that backup if a crash
        // occurred after the old package moved but before promotion.
        // Never promote an incomplete .staging directory.
        let backupMarker = ".dawproj.backup-"
        let candidates: [URL] = entries.compactMap { entry in
            let filename = entry.lastPathComponent
            if entry.pathExtension.lowercased() == ProjectFileManager.projectExtension,
               UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil {
                return entry
            }
            guard filename.hasPrefix("."),
                  let marker = filename.range(of: backupMarker) else { return nil }
            let start = filename.index(after: filename.startIndex)
            let identifier = String(filename[start..<marker.lowerBound])
            guard UUID(uuidString: identifier) != nil else { return nil }
            return rootDirectory.appendingPathComponent(identifier + ".dawproj")
        }

        var drafts: [StudioRecoveryDraft] = []
        for url in Set(candidates) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
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
        // FileManager may return a package URL marked isDirectory=true,
        // while draftURL(for:) is created without that URL flag. Compare
        // canonical filesystem paths, not the URL's directory hint.
        guard draft.fileURL.standardizedFileURL.path ==
                draftURL(for: draft.id).standardizedFileURL.path else {
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
