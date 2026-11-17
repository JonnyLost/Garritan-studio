import Foundation

/// Offline discovery for the Universal Instrument Importer. This phase never
/// extracts archives, parses proprietary files, or changes source recordings.
public enum StudioSamplerImportDiscovery {
    public enum Kind: String, Sendable, Equatable {
        case nativeInstrument, sfz, soundFont, giga, exs, kontakt, kontaktMulti
        case nksPreset, decentSampler, audio, archive, unknown
    }

    public enum Readiness: String, Sendable, Equatable {
        case existingImporter, requiresAdapter, sampleMapping, archiveInspection, unsupported
    }

    public struct Candidate: Sendable, Equatable {
        public let relativePath: String
        public let kind: Kind
        public let readiness: Readiness
    }

    public struct Report: Sendable {
        public let candidates: [Candidate]
        public let skippedSymbolicLinks: Int
        public let truncated: Bool
    }

    public enum DiscoveryError: Error {
        case invalidRoot
    }

    public static func classify(_ url: URL) -> (Kind, Readiness) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "studioinstrument": return (.nativeInstrument, .existingImporter)
        case "sfz": return (.sfz, .existingImporter)
        case "sf2": return (.soundFont, .existingImporter)
        case "gig": return (.giga, .existingImporter)
        case "exs", "exs24": return (.exs, .existingImporter)
        case "nki": return (.kontakt, .existingImporter) // Restricted legacy subset only
        case "nkm": return (.kontaktMulti, .requiresAdapter)
        case "nksf": return (.nksPreset, .requiresAdapter)
        case "dspreset", "dslibrary": return (.decentSampler, .requiresAdapter)
        case "wav", "wave", "aif", "aiff", "caf", "flac":
            return (.audio, .sampleMapping)
        case "zip": return (.archive, .archiveInspection)
        default: return (.unknown, .unsupported)
        }
    }

    /// Inventory a user-selected directory without following symlinks.
    /// Unknown files are omitted; limits bound metadata work for large libraries.
    public static func scanDirectory(_ root: URL,
                                     maxEntries: Int = 20_000,
                                     maxDepth: Int = 16) throws -> Report {
        let fm = FileManager.default
        // Validate the user-selected root BEFORE canonicalizing paths.
        // macOS may expose temporary directories as /var/... while the
        // directory enumerator returns /private/var/...; mixing these paths
        // corrupts the displayed relative path and breaks import discovery.
        let selectedRoot = root.standardizedFileURL
        let rootValues = try? selectedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isDirectory == true,
              rootValues?.isSymbolicLink != true else {
            throw DiscoveryError.invalidRoot
        }
        let rootURL = selectedRoot.resolvingSymlinksInPath().standardizedFileURL
        let entryLimit = max(1, min(maxEntries, 100_000))
        let depthLimit = max(0, min(maxDepth, 64))
        var pending: [(URL, Int)] = [(rootURL, 0)]
        var candidates: [Candidate] = []
        var skippedLinks = 0
        var inspected = 0
        var truncated = false
        while let (directory, depth) = pending.popLast() {
            let entries = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey,
                                              .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
            for entry in entries {
                if inspected >= entryLimit {
                    truncated = true
                    break
                }
                inspected += 1
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    skippedLinks += 1
                    continue
                }
                let (kind, readiness) = classify(entry)
                if kind == .nativeInstrument && values.isDirectory == true {
                    candidates.append(Candidate(
                        relativePath: String(entry.path.dropFirst(rootURL.path.count + 1)),
                        kind: kind, readiness: readiness))
                } else if values.isDirectory == true {
                    if depth < depthLimit { pending.append((entry, depth + 1)) }
                    else { truncated = true }
                } else if values.isRegularFile == true && kind != .unknown {
                    candidates.append(Candidate(
                        relativePath: String(entry.path.dropFirst(rootURL.path.count + 1)),
                        kind: kind, readiness: readiness))
                }
            }
            if truncated && inspected >= entryLimit { break }
        }
        return Report(candidates: candidates.sorted { $0.relativePath < $1.relativePath },
                      skippedSymbolicLinks: skippedLinks, truncated: truncated)
    }
}
