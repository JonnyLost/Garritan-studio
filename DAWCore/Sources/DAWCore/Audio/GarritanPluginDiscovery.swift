import Foundation

/// Read-only discovery of locally installed Garritan ARIA plugin bundles.
///
/// Discovery does not load plugins, inspect licensed samples, or change files.
/// The audio-host integration must separately validate and instantiate a result.
public enum GarritanPluginDiscovery {
    public enum Format: String, Codable, Sendable {
        case audioUnit
        case vst3
    }

    public struct Candidate: Equatable, Sendable {
        public let url: URL
        public let format: Format
        public let bundleIdentifier: String?
        public let displayName: String

        public init(url: URL, format: Format, bundleIdentifier: String?, displayName: String) {
            self.url = url
            self.format = format
            self.bundleIdentifier = bundleIdentifier
            self.displayName = displayName
        }
    }

    /// Standard macOS plugin locations. The user's home directory is supplied
    /// explicitly so tests and nonstandard installations remain deterministic.
    public static func defaultSearchRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components", isDirectory: true),
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Audio/Plug-Ins/Components", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Audio/Plug-Ins/VST3", isDirectory: true)
        ]
    }

    public static func discover(
        in roots: [URL] = defaultSearchRoots(),
        fileManager: FileManager = .default
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var seenPaths = Set<String>()

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                let format: Format
                switch ext {
                case "component": format = .audioUnit
                case "vst3": format = .vst3
                default: continue
                }

                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                let info = NSDictionary(contentsOf: entry.appendingPathComponent("Contents/Info.plist"))
                let name = (info?["CFBundleName"] as? String)
                    ?? (info?["CFBundleExecutable"] as? String)
                    ?? entry.deletingPathExtension().lastPathComponent
                let identifier = info?["CFBundleIdentifier"] as? String

                // A conservative candidate filter, not proof that a plugin is ARIA.
                let searchable = [name, identifier ?? "", entry.lastPathComponent]
                    .joined(separator: " ").lowercased()
                guard searchable.contains("aria") || searchable.contains("garritan") else {
                    continue
                }

                let normalizedPath = entry.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenPaths.insert(normalizedPath).inserted else { continue }
                candidates.append(Candidate(
                    url: entry,
                    format: format,
                    bundleIdentifier: identifier,
                    displayName: name
                ))
            }
        }

        return candidates.sorted {
            if $0.format.rawValue != $1.format.rawValue {
                return $0.format.rawValue < $1.format.rawValue
            }
            return $0.url.path < $1.url.path
        }
    }
}
