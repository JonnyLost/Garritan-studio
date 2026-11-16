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
        let root = instrument.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let roots = [root] + (samplesRoot.map {
            [$0.resolvingSymlinksInPath().standardizedFileURL]
        } ?? [])
        // Kontakt absolute paths are historical hints, NOT permission to
        // read arbitrary files outside user-authorized source folders.
        let isAbsolute = normalized.hasPrefix("/") ||
            normalized.contains(":") || normalized.hasPrefix("~")
        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent(filename))
            candidates.append(root.appendingPathComponent("Samples")
                                  .appendingPathComponent(filename))
            if !isAbsolute {
                candidates.append(root.appendingPathComponent(normalized))
            }
        }
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard roots.contains(where: {
                resolved.path.hasPrefix($0.path + "/")
            }) else { continue }
            let attributes = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            if attributes?.isRegularFile == true { return resolved }
        }
        throw ImportError.missingSample(filename)
    }
}
