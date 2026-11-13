import Foundation

// MARK: - Project File Manager

/// Handles saving and loading DAW projects as packages
public actor ProjectFileManager {
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Constants
    
    public static let projectExtension = "dawproj"

    /// A single URL normalization contract for Save, Save As and project history.
    /// Kept separate from disk serialization to preserve the legacy .dawproj format.
    public static func normalizedProjectURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() != projectExtension else {
            return standardized
        }
        return standardized.deletingPathExtension().appendingPathExtension(projectExtension)
    }
    
    // Package subdirectories
    private static let audioFolderName = "Audio Files"
    private static let pluginStatesFolderName = "Plugin States"
    private static let projectFileName = "project.json"
    
    // MARK: - Project Package Structure
    
    /// Project file structure (JSON-based)
    private struct ProjectFile: Codable {
        var version: Int
        var project: Project
        var audioFileManifest: [AudioFileEntry]
        var pluginStates: [PluginStateEntry]
    }
    
    private struct AudioFileEntry: Codable {
        var fileID: UUID
        var relativePath: String
        var originalPath: String  // For reference only
        var checksum: String?
    }
    
    private struct PluginStateEntry: Codable {
        var trackID: String
        var slotIndex: Int
        var pluginID: PluginIdentifier
        var stateData: Data
    }
    
    // MARK: - Saving
    
    /// Save project to a URL (creates a .dawproj package)
    public func save(project: Project, to url: URL) async throws {
        let fm = FileManager.default
        
        // Ensure URL has correct extension
        let packageURL = Self.normalizedProjectURL(url)
        
        // Assemble a complete replacement beside the original package. Never
        // delete the user's last successful save before all files are ready.
        let parentURL = packageURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".\(packageURL.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupURL = parentURL.appendingPathComponent(
            ".\(packageURL.lastPathComponent).backup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            // On an error, only the incomplete staging package is discarded.
            if fm.fileExists(atPath: stagingURL.path) {
                try? fm.removeItem(at: stagingURL)
            }
        }

        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        // Create subdirectories in the staging package.
        let audioDir = stagingURL.appendingPathComponent(Self.audioFolderName)
        let pluginsDir = stagingURL.appendingPathComponent(Self.pluginStatesFolderName)
        
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        
        // Copy audio files and build manifest
        var updatedProject = project
        var audioManifest: [AudioFileEntry] = []
        
        print("[ProjectFileManager] Project has \(project.audioFiles.count) audio files in audioFiles array")
        
        // Also check clips for audio references that might not be in audioFiles
        var clipAudioRefs: [AudioFileReference] = []
        for track in project.tracks {
            for clip in track.clips {
                if case .audio(let audioData) = clip.content {
                    clipAudioRefs.append(audioData.fileReference)
                    print("[ProjectFileManager] Found audio clip: \(clip.name) -> \(audioData.fileReference.originalPath)")
                }
            }
        }
        print("[ProjectFileManager] Found \(clipAudioRefs.count) audio references in clips")
        
        // Merge any missing audio references from clips into audioFiles
        for clipRef in clipAudioRefs {
            if !updatedProject.audioFiles.contains(where: { $0.fileID == clipRef.fileID }) {
                print("[ProjectFileManager] Adding missing audio ref from clip: \(clipRef.originalPath)")
                updatedProject.audioFiles.append(clipRef)
            }
        }
        
        print("[ProjectFileManager] After merge: \(updatedProject.audioFiles.count) audio files to save")
        
        for (index, audioRef) in updatedProject.audioFiles.enumerated() {
            let destFileName = "\(audioRef.fileID.uuidString).\(URL(fileURLWithPath: audioRef.originalPath).pathExtension.isEmpty ? "wav" : URL(fileURLWithPath: audioRef.originalPath).pathExtension)"
            let destURL = audioDir.appendingPathComponent(destFileName)
            let relativePath = "\(Self.audioFolderName)/\(destFileName)"
            
            // A previously saved recording may live inside the original package.
            // Copy it before replacing that package, even if the external source
            // file was moved or deleted.
            // Only a real file inside the saved "Audio Files" folder may
            // satisfy this fallback. An empty relativePath previously resolved
            // to the .dawproj DIRECTORY itself and was copied as a .wav.
            let relativeComponents = audioRef.relativePath.split(separator: "/").map(String.init)
            let isPackagedAudioPath = relativeComponents.count >= 2
                && relativeComponents.first == Self.audioFolderName
                && !relativeComponents.contains("..")
                && !relativeComponents.contains(".")
                && !audioRef.relativePath.hasPrefix("/")
            let existingPackagedFile = isPackagedAudioPath
                ? packageURL.appendingPathComponent(audioRef.relativePath)
                : nil
            let originalSource = findAudioFile(for: audioRef)
            let sourceURL = originalSource.flatMap { Self.isRegularFile($0) ? $0 : nil }
                ?? existingPackagedFile.flatMap { Self.isRegularFile($0) ? $0 : nil }
            guard let sourceURL else {
                // Never silently replace a valid project with missing audio
                // or a directory masquerading as an audio file.
                throw PersistenceError.fileNotFound(URL(fileURLWithPath: audioRef.originalPath))
            }
            try fm.copyItem(at: sourceURL, to: destURL)
            print("[ProjectFileManager] Copied audio: \(sourceURL.lastPathComponent) -> \(destFileName)")
            
            // Update the reference in project
            var updatedRef = audioRef
            updatedRef.relativePath = relativePath
            updatedProject.audioFiles[index] = updatedRef
            
            // Update clips that reference this file
            for trackIndex in 0..<updatedProject.tracks.count {
                for clipIndex in 0..<updatedProject.tracks[trackIndex].clips.count {
                    if case .audio(var audioData) = updatedProject.tracks[trackIndex].clips[clipIndex].content {
                        if audioData.fileReference.fileID == audioRef.fileID {
                            audioData.fileReference.relativePath = relativePath
                            updatedProject.tracks[trackIndex].clips[clipIndex].content = .audio(audioData)
                        }
                    }
                }
            }
            
            audioManifest.append(AudioFileEntry(
                fileID: audioRef.fileID,
                relativePath: relativePath,
                originalPath: audioRef.originalPath,
                checksum: nil
            ))
        }
        
        // Preserve any legacy plug-in state records inside the old package.
        // Existing track and rack slot state is also embedded in updatedProject.
        // Never silently discard earlier state while replacing an existing save.
        var legacyPluginStates: [PluginStateEntry] = []
        let previousJSON = packageURL.appendingPathComponent(Self.projectFileName)
        if fm.fileExists(atPath: previousJSON.path) {
            let previousData = try Data(contentsOf: previousJSON)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let previousFile = try decoder.decode(ProjectFile.self, from: previousData)
            legacyPluginStates = previousFile.pluginStates
        }

        let projectFile = ProjectFile(
            version: Project.currentFormatVersion,
            project: updatedProject,
            audioFileManifest: audioManifest,
            pluginStates: legacyPluginStates
        )
        
        // Encode and save
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(projectFile)
        let projectFileURL = stagingURL.appendingPathComponent(Self.projectFileName)
        try data.write(to: projectFileURL, options: .atomic)

        // Promote the complete staging package. If promotion fails, restore the
        // previous package instead of leaving a corrupt or partial project.
        let hadPreviousPackage = fm.fileExists(atPath: packageURL.path)
        if hadPreviousPackage {
            try fm.moveItem(at: packageURL, to: backupURL)
        }
        do {
            try fm.moveItem(at: stagingURL, to: packageURL)
        } catch {
            if hadPreviousPackage {
                try? fm.moveItem(at: backupURL, to: packageURL)
            }
            throw error
        }
        if hadPreviousPackage {
            // A cleanup failure must not turn a completed save into an error.
            try? fm.removeItem(at: backupURL)
        }

        print("[ProjectFileManager] Saved project to: \(packageURL.path)")
    }
    
    /// Reject package directories and other non-audio sources before copying.
    /// FileManager.fileExists alone returns true for directories.
    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Find the actual location of an audio file
    private func findAudioFile(for ref: AudioFileReference) -> URL? {
        let fm = FileManager.default
        
        print("[ProjectFileManager] Looking for audio file: \(ref.originalPath)")
        print("[ProjectFileManager]   relativePath: \(ref.relativePath)")
        
        // Try original path first (most common case)
        let originalURL = URL(fileURLWithPath: ref.originalPath)
        if fm.fileExists(atPath: originalURL.path) {
            print("[ProjectFileManager]   Found at original path")
            return originalURL
        }
        
        // Try with resolved symlinks (handles /var/folders vs /private/var/folders)
        let resolvedURL = originalURL.resolvingSymlinksInPath()
        if fm.fileExists(atPath: resolvedURL.path) {
            print("[ProjectFileManager]   Found at resolved path: \(resolvedURL.path)")
            return resolvedURL
        }
        
        // Get the filename for temp directory searches
        let filename = URL(fileURLWithPath: ref.originalPath).lastPathComponent
        
        // Try the standard temporary directory
        let tempURL = fm.temporaryDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: tempURL.path) {
            print("[ProjectFileManager]   Found in temp directory: \(tempURL.path)")
            return tempURL
        }
        
        // Try the DAWRecordings subdirectory (where V-Rack recordings are stored)
        let dawRecordingsURL = fm.temporaryDirectory.appendingPathComponent("DAWRecordings").appendingPathComponent(filename)
        if fm.fileExists(atPath: dawRecordingsURL.path) {
            print("[ProjectFileManager]   Found in DAWRecordings: \(dawRecordingsURL.path)")
            return dawRecordingsURL
        }
        
        // Prefer Studio recordings; retain a read-only fallback for projects
        // saved before Studio moved away from the inherited application path.
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for candidate in StudioRecordingLocations.recoveryURLs(
                forFilename: filename, inApplicationSupport: appSupport
            ) {
                if Self.isRegularFile(candidate) {
                    print("[ProjectFileManager]   Found recording: \(candidate.path)")
                    return candidate
                }
            }
        }
        
        // Try NSTemporaryDirectory() which might resolve differently
        let nsTemp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        if fm.fileExists(atPath: nsTemp.path) {
            print("[ProjectFileManager]   Found in NSTemporaryDirectory: \(nsTemp.path)")
            return nsTemp
        }
        
        // Try DAWRecordings in NSTemporaryDirectory
        let nsTempDAW = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DAWRecordings").appendingPathComponent(filename)
        if fm.fileExists(atPath: nsTempDAW.path) {
            print("[ProjectFileManager]   Found in NSTemporaryDirectory/DAWRecordings: \(nsTempDAW.path)")
            return nsTempDAW
        }
        
        // Try with /private prefix (macOS symlink resolution)
        if !ref.originalPath.hasPrefix("/private") && ref.originalPath.hasPrefix("/var") {
            let privatePath = "/private" + ref.originalPath
            if fm.fileExists(atPath: privatePath) {
                print("[ProjectFileManager]   Found with /private prefix: \(privatePath)")
                return URL(fileURLWithPath: privatePath)
            }
        }
        
        // Try without /private prefix
        if ref.originalPath.hasPrefix("/private/var") {
            let withoutPrivate = String(ref.originalPath.dropFirst("/private".count))
            if fm.fileExists(atPath: withoutPrivate) {
                print("[ProjectFileManager]   Found without /private prefix: \(withoutPrivate)")
                return URL(fileURLWithPath: withoutPrivate)
            }
        }
        
        // Try by filename in relative path
        let relFilename = URL(fileURLWithPath: ref.relativePath).lastPathComponent
        if relFilename != filename {
            let tempURL2 = fm.temporaryDirectory.appendingPathComponent(relFilename)
            if fm.fileExists(atPath: tempURL2.path) {
                print("[ProjectFileManager]   Found by relativePath filename: \(tempURL2.path)")
                return tempURL2
            }
            
            // Also try DAWRecordings with relative path filename
            let dawRecordingsURL2 = fm.temporaryDirectory.appendingPathComponent("DAWRecordings").appendingPathComponent(relFilename)
            if fm.fileExists(atPath: dawRecordingsURL2.path) {
                print("[ProjectFileManager]   Found by relativePath in DAWRecordings: \(dawRecordingsURL2.path)")
                return dawRecordingsURL2
            }
        }
        
        // Check if the original path contains a temp folder pattern and try to construct the actual path
        if ref.originalPath.contains("/T/") || ref.originalPath.contains("var/folders") {
            // The path is already a temp path, try to access it via URL(fileURLWithPath:)
            let tempPathURL = URL(fileURLWithPath: ref.originalPath)
            if fm.fileExists(atPath: tempPathURL.path) {
                print("[ProjectFileManager]   Found via temp path URL")
                return tempPathURL
            }
        }
        
        // Last resort: search DAWRecordings for any file matching the timestamp pattern
        if filename.contains("VRack_") {
            let dawRecordingsDir = fm.temporaryDirectory.appendingPathComponent("DAWRecordings")
            if let contents = try? fm.contentsOfDirectory(at: dawRecordingsDir, includingPropertiesForKeys: nil) {
                for file in contents where file.lastPathComponent == filename {
                    print("[ProjectFileManager]   Found by scanning DAWRecordings: \(file.path)")
                    return file
                }
            }
        }
        
        print("[ProjectFileManager]   NOT FOUND - audio file missing")
        return nil
    }
    
    /// Quick Save uses the same staged, rollback-capable package replacement
    /// as Save. Rewriting project.json in place could previously leave orphan
    /// audio files, retain missing-file references, or diverge from the manifest.
    /// A full staged save costs more I/O but protects the previous good project.
    public func saveQuick(project: Project, to url: URL) async throws {
        try await save(project: project, to: url)
    }

    // MARK: - Loading

    /// Rebase app-owned sampler recordings after JSON decoding. Missing
    /// recordings deliberately remain in the project so the user can use
    /// Edit Mapping → Relink Sample without losing musical settings.
    private func recoverManagedSamplerReferences(in project: inout Project) {
        for index in project.tracks.indices {
            guard let patch = project.tracks[index].studioSamplerPatch,
                  let resolved = try? StudioSamplerSampleLibrary.resolve(patch)
            else { continue }
            project.tracks[index].studioSamplerPatch = resolved
        }
    }
    
    /// Load project from a URL
    public func load(from url: URL) async throws -> Project {
        let fm = FileManager.default
        
        // Determine if it's a package or single file
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PersistenceError.fileNotFound(url)
        }
        
        let projectFileURL: URL
        let packageURL: URL
        
        if isDirectory.boolValue {
            // Project package
            packageURL = url
            projectFileURL = url.appendingPathComponent(Self.projectFileName)
        } else {
            // Single JSON file (legacy or exported)
            packageURL = url.deletingLastPathComponent()
            projectFileURL = url
        }
        
        guard fm.fileExists(atPath: projectFileURL.path) else {
            throw PersistenceError.fileNotFound(projectFileURL)
        }
        
        let data = try Data(contentsOf: projectFileURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Try loading as ProjectFile first
        do {
            let projectFile = try decoder.decode(ProjectFile.self, from: data)
            
            // Handle version migration if needed
            var project = projectFile.project
            project = try migrateIfNeeded(project, fromVersion: projectFile.version)
            
            print("[ProjectFileManager] Loading from package: \(packageURL.path)")
            print("[ProjectFileManager] Project has \(project.audioFiles.count) audio files")
            
            // Update audio file paths to be absolute (resolved against package)
            for i in 0..<project.audioFiles.count {
                let relativePath = project.audioFiles[i].relativePath
                let absolutePath = packageURL.appendingPathComponent(relativePath).path
                print("[ProjectFileManager] Audio file \(i): relative='\(relativePath)' -> absolute='\(absolutePath)'")
                print("[ProjectFileManager]   File exists: \(FileManager.default.fileExists(atPath: absolutePath))")
                project.audioFiles[i].originalPath = absolutePath
            }
            
            // Update clip references too
            for trackIndex in 0..<project.tracks.count {
                for clipIndex in 0..<project.tracks[trackIndex].clips.count {
                    if case .audio(var audioData) = project.tracks[trackIndex].clips[clipIndex].content {
                        let relativePath = audioData.fileReference.relativePath
                        let absolutePath = packageURL.appendingPathComponent(relativePath).path
                        print("[ProjectFileManager] Clip '\(project.tracks[trackIndex].clips[clipIndex].name)': relative='\(relativePath)'")
                        print("[ProjectFileManager]   -> absolute='\(absolutePath)'")
                        print("[ProjectFileManager]   File exists: \(FileManager.default.fileExists(atPath: absolutePath))")
                        audioData.fileReference.originalPath = absolutePath
                        project.tracks[trackIndex].clips[clipIndex].content = .audio(audioData)
                    }
                }
            }
            
            recoverManagedSamplerReferences(in: &project)
            print("[ProjectFileManager] Loaded project from: \(url.path)")
            return project
            
        } catch let persistenceError as PersistenceError {
            // Never reinterpret a newer, unsupported version as an old file.
            throw persistenceError
        } catch {
            // Try loading as plain Project (legacy format)
            print("[ProjectFileManager] Trying legacy format...")
            var legacyProject = try decoder.decode(Project.self, from: data)
            recoverManagedSamplerReferences(in: &legacyProject)
            return legacyProject
        }
    }
    
    /// Quick load for recent files check - just get metadata
    public func loadMetadata(from url: URL) async throws -> ProjectMetadataInfo {
        let fm = FileManager.default
        
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PersistenceError.fileNotFound(url)
        }
        
        let projectFileURL: URL
        if isDirectory.boolValue {
            projectFileURL = url.appendingPathComponent(Self.projectFileName)
        } else {
            projectFileURL = url
        }
        
        let data = try Data(contentsOf: projectFileURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Only decode the metadata portion
        struct MetadataOnly: Codable {
            var version: Int?
            var project: ProjectSummary
            
            struct ProjectSummary: Codable {
                var id: UUID
                var name: String
                var createdAt: Date
                var modifiedAt: Date
                var metadata: ProjectMetadata?
            }
        }
        
        if let meta = try? decoder.decode(MetadataOnly.self, from: data) {
            return ProjectMetadataInfo(
                id: meta.project.id,
                name: meta.project.name,
                createdAt: meta.project.createdAt,
                modifiedAt: meta.project.modifiedAt,
                fileURL: url
            )
        }

        // Historical single-file exports contain a bare Project, not a
        // ProjectFile envelope. These must also appear in Open Recent.
        let legacy = try decoder.decode(Project.self, from: data)
        return ProjectMetadataInfo(
            id: legacy.id,
            name: legacy.name,
            createdAt: legacy.createdAt,
            modifiedAt: legacy.modifiedAt,
            fileURL: url
        )
    }
    
    // MARK: - Migration
    
    private func migrateIfNeeded(_ project: Project, fromVersion: Int) throws -> Project {
        guard fromVersion <= Project.currentFormatVersion else {
            throw PersistenceError.invalidFormat(
                "Project format version \(fromVersion) is newer than this Studio build supports (\(Project.currentFormatVersion))."
            )
        }
        guard fromVersion >= 0 else {
            throw PersistenceError.invalidFormat("Negative project format version \(fromVersion).")
        }
        var migratedProject = project
        
        // Apply migrations in order
        if fromVersion < 1 {
            // Migration from version 0 to 1
            // (Example: add new required fields)
        }
        
        // Update format version
        migratedProject.formatVersion = Project.currentFormatVersion
        
        return migratedProject
    }
    
    // MARK: - Export
    
    /// Export project to a standard format
    public func export(
        project: Project,
        to url: URL,
        format: ExportFormat
    ) async throws {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: url)
            
        case .midi:
            try await exportAsMIDI(project: project, to: url)
        }
    }
    
    private func exportAsMIDI(project: Project, to url: URL) async throws {
        // A header by itself is not a valid Standard MIDI File. Until the
        // MIDI track/chunk writer is implemented, fail explicitly rather than
        // exporting an unreadable file that appears to have succeeded.
        throw PersistenceError.invalidFormat(
            "Standard MIDI export is not implemented yet; no file was created."
        )
    }
}

// MARK: - Errors

public enum PersistenceError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidFormat(String)
    case migrationFailed(from: Int, to: Int)
    case writeError(underlying: Error)
    case readError(underlying: Error)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .invalidFormat(let reason):
            return "Invalid project format: \(reason)"
        case .migrationFailed(let from, let to):
            return "Failed to migrate project from version \(from) to \(to)"
        case .writeError(let error):
            return "Failed to write file: \(error.localizedDescription)"
        case .readError(let error):
            return "Failed to read file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Export Format

public enum ExportFormat {
    case json
    case midi
}

// MARK: - Project Metadata Info

public struct ProjectMetadataInfo: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let fileURL: URL
}

// MARK: - Autosave Manager

/// Manages periodic autosaving of projects
@MainActor
public final class AutosaveManager: ObservableObject {
    
    private var autosaveTimer: Timer?
    private let fileManager: ProjectFileManager
    private var projectProvider: (() -> Project)?
    private var projectURL: URL?
    
    @Published public var lastAutosaveDate: Date?
    @Published public var hasUnsavedChanges: Bool = false
    
    /// Autosave interval in seconds
    public var autosaveInterval: TimeInterval = 60
    
    public init() {
        self.fileManager = ProjectFileManager()
    }
    
    public func configure(projectProvider: @escaping () -> Project) {
        self.projectProvider = projectProvider
    }
    
    public func startAutosave(for projectURL: URL) {
        self.projectURL = projectURL
        
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: autosaveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performAutosave()
            }
        }
    }
    
    public func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }
    
    private func performAutosave() async {
        guard hasUnsavedChanges, 
              let url = projectURL,
              let project = projectProvider?() else { return }
        
        do {
            try await fileManager.saveQuick(project: project, to: url)
            lastAutosaveDate = Date()
            hasUnsavedChanges = false
            print("[Autosave] Saved at \(Date())")
        } catch {
            print("[Autosave] Failed: \(error)")
        }
    }
    
    public func markUnsavedChanges() {
        hasUnsavedChanges = true
    }
}

// MARK: - Recent Projects Manager

@MainActor
public final class RecentProjectsManager: ObservableObject {
    
    @Published public private(set) var recentProjects: [ProjectMetadataInfo] = []
    
    private let maxRecentProjects = 10
    private let userDefaultsKey = "DAWRecentProjects"
    private var loadGeneration: UInt64 = 0

    public init() {
        loadRecentProjects()
    }
    
    public func addRecentProject(_ url: URL) {
        var urls = loadRecentURLs()
        
        // Remove if already exists
        urls.removeAll { $0 == url }
        
        // Add to front
        urls.insert(url, at: 0)
        
        // Limit count
        if urls.count > maxRecentProjects {
            urls = Array(urls.prefix(maxRecentProjects))
        }
        
        saveRecentURLs(urls)
        loadRecentProjects()
    }
    
    public func removeRecentProject(_ url: URL) {
        var urls = loadRecentURLs()
        urls.removeAll { $0 == url }
        saveRecentURLs(urls)
        loadRecentProjects()
    }
    
    public func clearRecentProjects() {
        loadGeneration &+= 1
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        recentProjects = []
    }
    
    private func loadRecentProjects() {
        loadGeneration &+= 1
        let generation = loadGeneration
        let urls = loadRecentURLs()

        Task {
            var projects: [ProjectMetadataInfo] = []
            let fileManager = ProjectFileManager()
            
            for url in urls {
                if let metadata = try? await fileManager.loadMetadata(from: url) {
                    projects.append(metadata)
                }
            }
            
            // An earlier asynchronous metadata read must never restore a
            // cleared/reordered recent-projects list.
            guard generation == self.loadGeneration else { return }
            self.recentProjects = projects
        }
    }
    
    private func loadRecentURLs() -> [URL] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let urls = try? JSONDecoder().decode([URL].self, from: data) else {
            return []
        }
        return urls
    }
    
    private func saveRecentURLs(_ urls: [URL]) {
        let data = try? JSONEncoder().encode(urls)
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
