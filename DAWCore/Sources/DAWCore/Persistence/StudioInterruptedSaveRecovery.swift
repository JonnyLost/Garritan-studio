import Foundation

/// Restore a completed .dawproj backup after a crash between staging and
/// promotion. Do not promote incomplete staging directories, replace an
/// existing package, or delete historical backups while recovering.
public enum StudioInterruptedSaveRecovery {
    @discardableResult
    public static func restoreIfNecessary(at url: URL) throws -> Bool {
        let fm = FileManager.default
        guard url.pathExtension.lowercased() == ProjectFileManager.projectExtension,
              !fm.fileExists(atPath: url.path) else { return false }

        let prefix = ".\(url.lastPathComponent).backup-"
        let siblings = try fm.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
            ], options: []
        )
        let backups = siblings.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted {
                let left = (try? $0.resourceValues(
                    forKeys: [URLResourceKey.contentModificationDateKey]
                ).contentModificationDate) ?? Date.distantPast
                let right = (try? $1.resourceValues(
                    forKeys: [URLResourceKey.contentModificationDateKey]
                ).contentModificationDate) ?? Date.distantPast
                return left > right
            }

        for backup in backups {
            guard let values = try? backup.resourceValues(
                forKeys: [URLResourceKey.isDirectoryKey, URLResourceKey.isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true,
                  isCompleteProject(backup) else { continue }

            guard !fm.fileExists(atPath: url.path) else { return false }
            try fm.moveItem(at: backup, to: url)
            return true
        }
        return false
    }

    private static func isCompleteProject(_ package: URL) -> Bool {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("project.json")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = dict["version"] as? Int,
              version >= 0, version <= Project.currentFormatVersion,
              let projectObject = dict["project"],
              dict["audioFileManifest"] is [Any],
              dict["pluginStates"] is [Any],
              let projectData = try? JSONSerialization.data(withJSONObject: projectObject)
        else { return false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Project.self, from: projectData)) != nil
    }
}
