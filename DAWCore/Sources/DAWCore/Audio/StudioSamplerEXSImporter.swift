import Foundation
import AVFoundation

/// EXS24 to native Studio sampler conversion. Supported source audio stays
/// separate from the .exs file and is copied only after the entire mapping
/// has been validated. Group behaviors that cannot be reproduced are rejected
/// rather than silently replaced by the wrong performance.
public enum StudioSamplerEXSImporter {
    public struct Result: Sendable {
        public let patch: StudioSamplerPatch
        public let instrumentName: String
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case missingAudio(String)
        case unsafeReference(String)
        case unsupportedBehavior(String)
        case invalidSample(String)
        case invalidZone(String)
        case tooManyZones

        public var errorDescription: String? {
            switch self {
            case .missingAudio(let sample):
                return "An EXS24 audio sample could not be found: \(sample)"
            case .unsafeReference(let sample):
                return "The EXS24 instrument has an unsafe audio reference: \(sample)"
            case .unsupportedBehavior(let reason):
                return "EXS24 compatibility is not yet available for \(reason)."
            case .invalidSample(let sample):
                return "The EXS24 instrument references unsupported or invalid audio: \(sample)"
            case .invalidZone(let reason):
                return "EXS24 sample-zone mapping is invalid: \(reason)"
            case .tooManyZones:
                return "Studio currently supports at most 128 sampler zones."
            }
        }
    }

    /// Preview resolves the exact referenced recordings and inspects their
    /// durations, without modifying the original instrument or any samples.
    public static func preview(_ instrumentURL: URL) throws -> Result {
        let catalog = try StudioSamplerEXSReader.inspect(instrumentURL)
        guard catalog.zones.count <= 128 else { throw ImportError.tooManyZones }
        var warnings = Set(catalog.warnings)
        var resolved: [Int: (url: URL, frames: UInt32, rate: Double)] = [:]
        for sampleIndex in Set(catalog.zones.map(\.sampleIndex)).sorted() {
            guard let sample = catalog.samples[sampleIndex] else {
                throw ImportError.missingAudio("sample index \(sampleIndex)")
            }
            let url = try resolveSample(sample, relativeTo: instrumentURL)
            let file = try AVAudioFile(forReading: url)
            guard (1...2).contains(Int(file.processingFormat.channelCount)),
                  file.processingFormat.sampleRate > 0,
                  file.length >= 2, file.length <= 500_000_000,
                  file.length <= Int64(UInt32.max) else {
                throw ImportError.invalidSample(url.lastPathComponent)
            }
            resolved[sampleIndex] = (url, UInt32(file.length),
                                     file.processingFormat.sampleRate)
            if sample.sampleRate != 0 &&
                abs(Double(sample.sampleRate) - file.processingFormat.sampleRate) > 1 {
                warnings.insert("The recorded sample rate for \(sample.name) differs from its audio file; Studio uses the audio file.")
            }
        }

        var zones: [StudioSamplerZone] = []
        for info in catalog.zones {
            guard let audio = resolved[info.sampleIndex] else {
                throw ImportError.invalidZone("missing decoded audio reference")
            }
            let on = info.flags & 0x01 != 0
            let pitchDisabled = info.flags & 0x02 != 0
            let reverse = info.flags & 0x04 != 0
            if on || pitchDisabled || reverse {
                throw ImportError.unsupportedBehavior(
                    "EXS24 one-shot, no-pitch-tracking, or reverse-playback zones")
            }
            let group: StudioSamplerEXSReader.Group?
            if let id = info.groupIndex {
                guard let stored = catalog.groups[id] else {
                    throw ImportError.invalidZone("missing group \(id)")
                }
                if stored.mute || stored.enableByType != 0 ||
                    (stored.roundRobinPosition != -1 &&
                     stored.roundRobinPosition != 0) ||
                    stored.velocityCrossfade != 0 ||
                    stored.keyCrossfade != 0 {
                    throw ImportError.unsupportedBehavior(
                        "group triggers, crossfades, round robin, or muted groups")
                }
                group = stored
            } else {
                group = nil
            }

            var lowVelocity = info.flags & 0x08 != 0
                ? Int(info.velocityLow) : 1
            var highVelocity = info.flags & 0x08 != 0
                ? Int(info.velocityHigh) : 127
            if let group, group.velocityLow != 0 || group.velocityHigh != 0 {
                lowVelocity = max(lowVelocity, Int(group.velocityLow))
                highVelocity = min(highVelocity, Int(group.velocityHigh))
            }
            if lowVelocity > highVelocity {
                // A group/zone velocity intersection can intentionally be
                // empty. Drop only this silent mapping.
                continue
            }
            guard highVelocity >= 1 else { continue }

            let adjustedRoot = Int(info.rootNote) -
                Int(info.coarseTuning)
            guard (0...127).contains(adjustedRoot) else {
                throw ImportError.invalidZone("coarse tuning moves root outside MIDI range")
            }
            if info.fineTuning != 0 || info.pan != 0 || info.gain != 0 {
                warnings.insert("EXS24 fine tuning, individual zone pan and gain are not yet reproduced.")
            }
            let availableFrames = audio.frames
            let start = info.trimStart
            let end = info.trimEnd == 0 ? availableFrames : info.trimEnd
            guard start < end, end <= availableFrames, end - start >= 2 else {
                throw ImportError.invalidZone("sample trim exceeds \(audio.url.lastPathComponent)")
            }
            var zone = StudioSamplerZone(
                sampleURL: audio.url, rootNote: UInt8(adjustedRoot),
                lowestNote: info.keyLow, highestNote: info.keyHigh,
                lowestVelocity: UInt8(max(1, lowVelocity)),
                highestVelocity: UInt8(highVelocity))
            if start != 0 { zone.trimStartFrame = start }
            if end != availableFrames { zone.trimEndFrame = end }
            let releaseTrigger = group?.releaseTrigger == true
            if releaseTrigger { zone.isReleaseTrigger = true }
            if info.loopFlags & 0x01 != 0 {
                guard !releaseTrigger else {
                    throw ImportError.unsupportedBehavior("a looped release-trigger sample")
                }
                guard info.loopDirection == 0 else {
                    throw ImportError.unsupportedBehavior(
                        "reverse or alternating EXS24 loop direction")
                }
                guard info.loopStart >= start, info.loopEnd <= end,
                      info.loopEnd > info.loopStart,
                      info.loopEnd - info.loopStart >= 4 else {
                    throw ImportError.invalidZone("invalid sample loop")
                }
                zone.loopStartFrame = info.loopStart
                zone.loopEndFrame = info.loopEnd
                if info.loopCrossfadeMilliseconds > 0 {
                    let requested = Double(info.loopCrossfadeMilliseconds) *
                        audio.rate / 1000
                    let span = Double(info.loopEnd - info.loopStart)
                    guard requested.isFinite, requested >= 0,
                          requested <= span / 2,
                          requested <= Double(UInt32.max) else {
                        throw ImportError.invalidZone("unsupported loop crossfade")
                    }
                    zone.loopCrossfadeFrames = UInt32(requested.rounded())
                }
                if info.loopFlags & 0x04 == 0 {
                    warnings.insert("EXS24's keep-looping-through-release behavior is not yet reproduced.")
                }
            }
            if !zone.isValid { throw ImportError.invalidZone("native Studio zone limits") }
            zones.append(zone)
        }
        guard !zones.isEmpty else {
            throw ImportError.invalidZone("no playable mappings remain")
        }
        let patch = StudioSamplerPatch(zones: zones)
        guard patch.isValid else { throw ImportError.invalidZone("invalid Studio patch") }
        return Result(patch: patch, instrumentName: catalog.name,
                      warnings: warnings.sorted())
    }

    /// Copy only the distinct, validated recordings into Studio-managed
    /// storage. The existing library's transaction rolls back failed copies.
    /// Original .exs and source audio files remain untouched.
    public static func importInstrument(_ instrumentURL: URL,
                                        into directory: URL? = nil) throws -> Result {
        let result = try preview(instrumentURL)
        var originalURLs: [URL] = []
        var lookup: [String: Int] = [:]
        for zone in result.patch.zones {
            if lookup[zone.filePath] == nil {
                lookup[zone.filePath] = originalURLs.count
                originalURLs.append(URL(fileURLWithPath: zone.filePath))
            }
        }
        let copied = try StudioSamplerSampleLibrary.importFiles(
            originalURLs, into: directory)
        var patch = result.patch
        for index in patch.zones.indices {
            guard let position = lookup[patch.zones[index].filePath] else {
                throw ImportError.invalidZone("copy mapping")
            }
            patch.zones[index].filePath = copied[position].path
            patch.zones[index].managedFileName = directory == nil
                ? StudioSamplerSampleLibrary.managedName(for: copied[position])
                : nil
        }
        return Result(patch: patch, instrumentName: result.instrumentName,
                      warnings: result.warnings)
    }

    private static func resolveSample(_ sample: StudioSamplerEXSReader.Sample,
                                      relativeTo instrument: URL) throws -> URL {
        let folder = instrument.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let stored = sample.directoryOrPath.replacingOccurrences(
            of: "\\", with: "/")
        let providedName = sample.fileName
        let filename = providedName.isEmpty
            ? URL(fileURLWithPath: stored).lastPathComponent
            : URL(fileURLWithPath: providedName).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"),
              providedName == "" || providedName == filename else {
            throw ImportError.unsafeReference(sample.name)
        }
        let permitted = Set(["wav", "wave", "aif", "aiff", "caf"])
        guard permitted.contains(URL(fileURLWithPath: filename)
            .pathExtension.lowercased()) else {
            throw ImportError.invalidSample(filename)
        }
        var candidates: [URL] = [
            folder.appendingPathComponent(filename),
            folder.appendingPathComponent("Samples").appendingPathComponent(filename)
        ]
        if !stored.isEmpty {
            if stored.hasPrefix("/") {
                let absolute = URL(fileURLWithPath: stored)
                if absolute.lastPathComponent == filename {
                    candidates.append(absolute)
                } else {
                    candidates.append(absolute.appendingPathComponent(filename))
                }
            } else {
                let pieces = stored.split(separator: "/", omittingEmptySubsequences: false)
                guard !pieces.contains(".."), !stored.hasPrefix("~"),
                      !stored.contains(":") else {
                    throw ImportError.unsafeReference(sample.name)
                }
                let relative = folder.appendingPathComponent(stored)
                candidates.append(relative.lastPathComponent == filename
                    ? relative : relative.appendingPathComponent(filename))
            }
        }
        for (index, candidate) in candidates.enumerated() {
            let actual = candidate.resolvingSymlinksInPath().standardizedFileURL
            let attr = try? actual.resourceValues(forKeys: [.isRegularFileKey])
            if attr?.isRegularFile != true { continue }
            // Relative references cannot traverse outside the user-selected
            // instrument directory, including through symlinks.
            if index != 2 && !actual.path.hasPrefix(folder.path + "/") {
                continue
            }
            if actual.pathExtension.lowercased() !=
                URL(fileURLWithPath: filename).pathExtension.lowercased() {
                continue
            }
            return actual
        }
        throw ImportError.missingAudio(filename)
    }
}
