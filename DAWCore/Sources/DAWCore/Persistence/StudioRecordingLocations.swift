import Foundation

/// Studio recording storage, with non-destructive recovery of old sessions.
public enum StudioRecordingLocations {
    public static let studioDirectoryName = "Studio/Recordings"
    public static let legacyDirectoryName = "MusioCreate/Recordings"

    /// Prefer the native Studio folder; keep historical recordings readable.
    public static func recoveryURLs(
        forFilename filename: String,
        inApplicationSupport directory: URL
    ) -> [URL] {
        [studioDirectoryName, legacyDirectoryName].map { folder in
            directory.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
        }
    }
}
