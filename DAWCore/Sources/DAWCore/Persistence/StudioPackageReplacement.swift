import Foundation

/// Keep completed backups for recovery. Never delete the last good version.
/// Injected moves allow deterministic failure tests without filesystem permissions tricks.
enum StudioPackageReplacement {
    static func promote(staging: URL, destination: URL, backup: URL,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let existed = FileManager.default.fileExists(atPath: destination.path)
        if existed { try move(destination, backup) }
        do {
            try move(staging, destination)
        } catch {
            if existed { try? move(backup, destination) }
            // If rollback also fails, the completed backup remains discoverable.
            throw error
        }
    }
}
