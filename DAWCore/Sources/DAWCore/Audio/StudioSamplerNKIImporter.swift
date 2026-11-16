import Foundation
import AVFoundation

/// Imports only verified, unprotected legacy K2 NKI maps that reference
/// ordinary external recordings. Studio never needs Kontakt at playback.
/// Monoliths, NCW, NKX/NKS containers and protected instruments are not
/// decrypted, extracted or approximated.
public enum StudioSamplerNKIImporter {
    public struct Result: Sendable {
        public let patch: StudioSamplerPatch
        public let name: String
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case unsupportedSample(String)
        case missingSample(String)
        case unsafeSamplePath(String)
        case ambiguousSample(String)
        case invalidZone(String)
        case tooManyZones

        public var errorDescription: String? {
            switch self {
            case .unsupportedSample(let path):
                return "This Kontakt sample format cannot be imported natively yet: \(path). Only external WAV, AIFF and CAF files are supported."
            case .missingSample(let path):
                return "Kontakt sample not found in the instrument's authorized folders: \(path)"
            case .unsafeSamplePath(let path):
                return "The Kontakt sample path is unsafe or escapes the selected folder: \(path)"
            case .ambiguousSample(let name):
                return "Multiple authorized recordings match \(name). Put the recording in the matching sample subfolder or select its exact parent folder; Studio will not guess."
            case .invalidZone(let reason):
                return "Kontakt zone does not match the audio recording: \(reason)"
            case .tooManyZones:
                return "Studio currently supports at most 128 sample zones per instrument."
            }
        }
    }

    /// Performs complete audio/sample validation without writing anything.
    public static func preview(_ url: URL, samplesRoot: URL? = nil) throws -> Result {
        let catalog = try StudioSamplerNKIReader.inspect(url)
        guard catalog.zones.count <= 128 else { throw ImportError.tooManyZones }
        var audioCache: [String: (frames: UInt32, sampleRate: Double)] = [:]
        var zones: [StudioSamplerZone] = []
        for mapping in catalog.zones {
            let sampleURL = try resolve(mapping.samplePath, relativeTo: url,
                                        samplesRoot: samplesRoot)
            let metadata: (frames: UInt32, sampleRate: Double)
            if let cached = audioCache[sampleURL.path] {
                metadata = cached
            } else {
                let file: AVAudioFile
                do { file = try AVAudioFile(forReading: sampleURL) }
                catch { throw ImportError.unsupportedSample(
                    sampleURL.lastPathComponent) }
                guard (1...2).contains(Int(file.processingFormat.channelCount)),
                      file.processingFormat.sampleRate.isFinite,
                      file.processingFormat.sampleRate > 0,
                      file.length >= 2, file.length <= 500_000_000 else {
                    throw ImportError.unsupportedSample(sampleURL.lastPathComponent)
                }
                metadata = (UInt32(file.length), file.processingFormat.sampleRate)
                audioCache[sampleURL.path] = metadata
            }
            let end = mapping.sampleEnd ?? metadata.frames
            guard mapping.sampleStart < end, end <= metadata.frames,
                  end - mapping.sampleStart >= 2 else {
                throw ImportError.invalidZone(
                    "sample trim exceeds \(sampleURL.lastPathComponent)")
            }
            var zone = StudioSamplerZone(
                sampleURL: sampleURL, rootNote: mapping.rootKey,
                lowestNote: mapping.lowKey, highestNote: mapping.highKey,
                lowestVelocity: mapping.lowVelocity,
                highestVelocity: mapping.highVelocity)
            if mapping.sampleStart > 0 {
                zone.trimStartFrame = mapping.sampleStart
            }
            if end < metadata.frames { zone.trimEndFrame = end }
            if mapping.releaseTrigger { zone.isReleaseTrigger = true }
            if let loopStart = mapping.loopStart,
               let loopEnd = mapping.loopEnd {
                guard !mapping.releaseTrigger,
                      loopStart >= mapping.sampleStart,
                      loopEnd <= end, loopStart < loopEnd,
                      loopEnd - loopStart >= 4 else {
                    throw ImportError.invalidZone(
                        "sample loop exceeds \(sampleURL.lastPathComponent)")
                }
                zone.loopStartFrame = loopStart
                zone.loopEndFrame = loopEnd
            }
            guard zone.isValid else {
                throw ImportError.invalidZone("invalid Studio sampler mapping")
            }
            zones.append(zone)
        }
        let patch = StudioSamplerPatch(zones: zones)
        guard patch.isValid else {
            throw ImportError.invalidZone("no playable Kontakt zones")
        }
        return Result(patch: patch, name: catalog.name,
                      warnings: catalog.warnings)
    }

    /// Copies each distinct validated audio recording exactly once into
    /// Studio's native sample library. Original NKI and sample files remain
    /// untouched; the managed library handles rollback on copy failure.
    public static func importInstrument(_ url: URL,
                                        into directory: URL? = nil,
                                        samplesRoot: URL? = nil) throws -> Result {
        let previewed = try preview(url, samplesRoot: samplesRoot)
        var originals: [URL] = []
        var lookup: [String: Int] = [:]
        for zone in previewed.patch.zones {
            if lookup[zone.filePath] == nil {
                lookup[zone.filePath] = originals.count
                originals.append(zone.sampleURL)
            }
        }
        let installed = try StudioSamplerSampleLibrary.importFiles(
            originals, into: directory)
        var patch = previewed.patch
        for index in patch.zones.indices {
            guard let i = lookup[patch.zones[index].filePath] else {
                throw ImportError.invalidZone("missing managed sample reference")
            }
            patch.zones[index].filePath = installed[i].path
            patch.zones[index].managedFileName = directory == nil
                ? StudioSamplerSampleLibrary.managedName(for: installed[i])
                : nil
        }
        guard patch.isValid else {
            throw ImportError.invalidZone("invalid restored Studio sampler mapping")
        }
        return Result(patch: patch, name: previewed.name,
                      warnings: previewed.warnings)
    }

    /// Prefer the NKI's declared relative hierarchy. A basename is only
    /// used as a last-resort relinking hint when exactly one authorized audio
    /// file matches; otherwise two sections could silently play the wrong
    /// recording (e.g. Strings/tone.wav vs Brass/tone.wav).
    private static func resolve(_ raw: String, relativeTo instrument: URL,
                                samplesRoot: URL?) throws -> URL {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let filename = URL(fileURLWithPath: normalized).lastPathComponent
        guard !normalized.isEmpty, !filename.isEmpty,
              filename != ".", filename != "..", !raw.contains("\0"),
              !normalized.split(separator: "/").contains("..") else {
            throw ImportError.unsafeSamplePath(raw)
        }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard Set(["wav", "wave", "aif", "aiff", "caf"]).contains(ext) else {
            throw ImportError.unsupportedSample(filename)
        }
        let instrumentFolder = instrument.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let roots = [instrumentFolder] + (samplesRoot.map {
            [$0.resolvingSymlinksInPath().standardizedFileURL]
        } ?? [])
        // A source path, even an absolute Windows/macOS path, cannot grant
        // permission to read outside these user-authorized folders.
        func existingAuthorizedFile(_ candidate: URL) -> URL? {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard roots.contains(where: {
                resolved.path.hasPrefix($0.path + "/")
            }) else { return nil }
            let attributes = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            return attributes?.isRegularFile == true ? resolved : nil
        }
        let isAbsolute = normalized.hasPrefix("/") ||
            normalized.contains(":") || normalized.hasPrefix("~")
        if !isAbsolute {
            // The sample's original subdirectory is authoritative. This
            // prevents a stray root/tone.wav from shadowing
            // root/Samples/Strings/tone.wav.
            for root in roots {
                if let exact = existingAuthorizedFile(
                    root.appendingPathComponent(normalized)) {
                    return exact
                }
            }
            let samplesPrefix = "Samples/"
            let withinSamples = normalized.hasPrefix(samplesPrefix)
                ? String(normalized.dropFirst(samplesPrefix.count))
                : normalized
            for root in roots {
                if let conventional = existingAuthorizedFile(
                    root.appendingPathComponent("Samples")
                        .appendingPathComponent(withinSamples)) {
                    return conventional
                }
                // The user may select the Samples folder itself instead of
                // its parent when relinking "Samples/Strings/tone.wav".
                if normalized.hasPrefix(samplesPrefix),
                   let granted = existingAuthorizedFile(
                    root.appendingPathComponent(withinSamples)) {
                    return granted
                }
            }
        }
        // Basename recovery is useful for relocated legacy libraries, but
        // only if the match is unambiguous among authorized candidates.
        var matches: [String: URL] = [:]
        for root in roots {
            for candidate in [
                root.appendingPathComponent(filename),
                root.appendingPathComponent("Samples")
                    .appendingPathComponent(filename)
            ] {
                if let found = existingAuthorizedFile(candidate) {
                    matches[found.path] = found
                }
            }
        }
        if matches.count > 1 {
            throw ImportError.ambiguousSample(filename)
        }
        if let found = matches.values.first { return found }
        throw ImportError.missingSample(filename)
    }
}
