import Foundation

/// Validate only the paths Studio owns inside a .dawproj package.
/// A relative audio reference must stay under the package's Audio Files
/// directory even when intermediate components are symlinks.
public enum StudioProjectPackagePaths {
    public static func packagedAudioURL(
        relativePath: String, inside packageURL: URL
    ) -> URL? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(
            separator: "/", omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count >= 2,
              components.first == "Audio Files",
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
              }) else { return nil }

        let folder = packageURL.appendingPathComponent(
            "Audio Files", isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let candidate = packageURL.appendingPathComponent(
            relativePath, isDirectory: false
        )
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        let folderPrefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard canonical.path.hasPrefix(folderPrefix) else { return nil }
        return candidate
    }
}
