import Foundation

/// Original Studio Sampler recordings are imported into app-owned Application
/// Support before file-picker security-scoped access ends. The project stores
/// an optional managed filename, so moving a project between user accounts
/// on the same Mac installation does not tie it to an old absolute home path.
///
/// A managed sample is NOT an external bookmark: the app already owns a
/// private copy and therefore does not require ongoing security scope.
public enum StudioSamplerSampleLibrary {
    public enum LibraryError: Error, LocalizedError {
        case missingSample(String)
        case invalidManagedName(String)
        case invalidSource(URL)

        public var errorDescription: String? {
            switch self {
            case .missingSample(let name):
                return "Studio Sampler cannot find \"\(name)\". Open Edit Mapping and use Relink Sample."
            case .invalidManagedName(let name):
                return "Invalid managed sampler reference: \(name)"
            case .invalidSource(let url):
                return "The selected sample is not a readable recording: \(url.lastPathComponent)"
            }
        }
    }

    public static func libraryDirectory() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent(
            "GarritanStudio/SamplerSamples", isDirectory: true
        )
    }

    /// Validate a single filename, never an arbitrary relative path. This
    /// prevents JSON references such as ../ or absolute paths escaping the
    /// app-owned sample library during project reopen.
    public static func validManagedFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") &&
        name == URL(fileURLWithPath: name).lastPathComponent
    }

    public static func managedURL(forFileName name: String,
                                  in directory: URL? = nil) throws -> URL {
        guard validManagedFileName(name) else {
            throw LibraryError.invalidManagedName(name)
        }
        return (try directory ?? libraryDirectory())
            .appendingPathComponent(name, isDirectory: false)
    }

    /// Only claim ownership when the file is in Studio's managed folder.
    /// An arbitrary external recording must not be converted into an
    /// app-owned reference without first importing a private copy.
    public static func managedName(for url: URL,
                                   in directory: URL? = nil) -> String? {
        guard let folder = try? directory ?? libraryDirectory() else { return nil }
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent()
        guard parent == folder.standardizedFileURL else { return nil }
        let name = normalized.lastPathComponent
        return validManagedFileName(name) ? name : nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Earlier versions saved only an absolute path to the app-owned copy.
    /// Detect its UUID-prefixed imported filename without accepting a
    /// lookalike filename from a completely unrelated directory.
    private static func formerManagedName(for url: URL) -> String? {
        let parent = url.deletingLastPathComponent()
        guard parent.lastPathComponent == "SamplerSamples",
              parent.deletingLastPathComponent().lastPathComponent == "GarritanStudio"
        else { return nil }
        let name = url.lastPathComponent
        guard name.count > 37,
              UUID(uuidString: String(name.prefix(36))) != nil,
              name[name.index(name.startIndex, offsetBy: 36)] == "-",
              validManagedFileName(name) else { return nil }
        return name
    }

    /// Resolve and normalize a saved patch before changing the audio graph.
    /// Only the file's location is repaired; note ranges, trims, fades and
    /// articulation maps remain untouched. No broad filename searching and
    /// no silently substituted unrelated samples.
    public static func resolve(_ patch: StudioSamplerPatch,
                               in directory: URL? = nil) throws -> StudioSamplerPatch {
        var restored = patch
        for index in restored.zones.indices {
            let zone = restored.zones[index]
            let oldURL = URL(fileURLWithPath: zone.filePath)
            let savedName = zone.managedFileName
            let recoveredName = savedName ?? formerManagedName(for: oldURL)
            if let name = recoveredName {
                let target = try managedURL(forFileName: name, in: directory)
                guard isRegularFile(target) else {
                    throw LibraryError.missingSample(name)
                }
                restored.zones[index].filePath = target.path
                restored.zones[index].managedFileName = name
            } else {
                guard isRegularFile(oldURL) else {
                    throw LibraryError.missingSample(oldURL.lastPathComponent)
                }
            }
        }
        return restored
    }

    /// Import and keep originals untouched. If any copy fails, roll back only
    /// files made by this batch. This is also used by the Relink Sample UI.
    public static func importFiles(_ urls: [URL],
                                   into directory: URL? = nil) throws -> [URL] {
        guard !urls.isEmpty else {
            throw StudioSamplerMappingBuilder.MappingError.emptySelection
        }
        let fm = FileManager.default
        let folder = try directory ?? libraryDirectory()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var copied: [URL] = []
        var newlyCreated: [URL] = []
        do {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard isRegularFile(url) else { throw LibraryError.invalidSource(url) }
                if url.deletingLastPathComponent().standardizedFileURL ==
                    folder.standardizedFileURL {
                    copied.append(url)
                    continue
                }
                let destination = folder.appendingPathComponent(
                    "\(UUID().uuidString)-\(url.lastPathComponent)"
                )
                try fm.copyItem(at: url, to: destination)
                newlyCreated.append(destination)
                copied.append(destination)
            }
            return copied
        } catch {
            for url in newlyCreated { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
