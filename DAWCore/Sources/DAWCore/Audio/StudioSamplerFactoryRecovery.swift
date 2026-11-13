import Foundation

/// A failed mapping import must not destroy a composer's captured performance.
/// Keep independent copies outside the temporary directory, but only for
/// files that were CREATED by Instrument Factory; never relocate externally
/// supplied user audio.
public enum StudioSamplerFactoryRecovery {
    public enum RecoveryError: Error, LocalizedError {
        case invalidSource

        public var errorDescription: String? {
            "Only Instrument Factory's prepared temporary WAV files can be recovered."
        }
    }

    public static func preserve(_ takes: [StudioSamplerFactoryTake]) throws -> URL {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask, appropriateFor: nil,
                              create: true)
            .appendingPathComponent("GarritanStudio/SamplerFactoryRecoveries",
                                    isDirectory: true)
        let tempRoot = fm.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL
        let sources = takes.map(\.source)
        guard !sources.isEmpty, sources.allSatisfy({ url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return url.lastPathComponent.hasPrefix("StudioFactoryPrepared-") &&
                url.pathExtension.lowercased() == "wav" &&
                resolved.deletingLastPathComponent() == tempRoot &&
                (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
                    .map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true
        }) else { throw RecoveryError.invalidSource }
        let folder = root.appendingPathComponent(UUID().uuidString,
                                                  isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed { try? fm.removeItem(at: folder) }
        }
        // Copy everything first. A partial backup is never presented as a
        // complete recovery set. Only then can the caller delete temporary
        // originals, after a confirmed successful copy.
        for source in sources {
            let output = folder.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: output)
        }
        completed = true
        return folder
    }
}
