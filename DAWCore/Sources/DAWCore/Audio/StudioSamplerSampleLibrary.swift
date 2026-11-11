import Foundation

/// Copy imported recordings into stable app-owned storage before stopping
/// security-scoped access from the SwiftUI file picker. This is a local sample
/// library (not yet a relocatable project package or streaming implementation).
public enum StudioSamplerSampleLibrary {
    public static func importFiles(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else {
            throw StudioSamplerMappingBuilder.MappingError.emptySelection
        }
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appendingPathComponent(
            "GarritanStudio/SamplerSamples", isDirectory: true
        )
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true
        )

        var copied: [URL] = []
        do {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if url.deletingLastPathComponent().standardizedFileURL ==
                    folder.standardizedFileURL {
                    copied.append(url)
                    continue
                }
                let destination = folder.appendingPathComponent(
                    "\(UUID().uuidString)-\(url.lastPathComponent)"
                )
                try fileManager.copyItem(at: url, to: destination)
                copied.append(destination)
            }
            return copied
        } catch {
            // Only undo imports staged by this batch; never delete a source file
            // already inside our sample library.
            for url in copied where url.deletingLastPathComponent().standardizedFileURL ==
                folder.standardizedFileURL {
                if url.lastPathComponent.contains("-") {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }
    }
}
