import Foundation
import AVFoundation

/// First-stage SFZ compatibility reader. Translates supported SFZ regions into
/// Studio's editable native mapping; it does not execute SFZ scripts or effects.
/// Import is an explicit offline operation, never performed on the audio thread.
public enum StudioSamplerSFZImporter {
    public struct Result: Sendable {
        public let patch: StudioSamplerPatch
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case unreadable
        case noRegions
        case tooManyRegions
        case invalidRegion(Int, String)
        case unsafeSamplePath(String)
        case missingSample(String)
        case unsupportedEncoding

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The SFZ instrument cannot be read."
            case .noRegions: return "The SFZ instrument has no playable sample regions."
            case .tooManyRegions: return "Studio currently supports up to 128 sample zones per instrument."
            case .invalidRegion(let line, let reason): return "Invalid SFZ region near line \(line): \(reason)"
            case .unsafeSamplePath(let path): return "The SFZ sample path is unsafe: \(path)"
            case .missingSample(let path): return "The SFZ sample is missing: \(path)"
            case .unsupportedEncoding: return "This SFZ text encoding is not supported."
            }
        }
    }

    private struct Region {
        var line: Int
        var values: [String: String]
    }

    /// Read and validate mappings without copying or changing source recordings.
    /// The caller can present warnings before importing into the managed library.
    public static func preview(_ url: URL,
                               samplesRoot: URL? = nil) throws -> Result {
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000 else {
            throw ImportError.unreadable
        }
        guard let source = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .windowsCP1252) else {
            throw ImportError.unsupportedEncoding
        }
        let parsed = parse(source)
        guard !parsed.isEmpty else { throw ImportError.noRegions }
        guard parsed.count <= 128 else { throw ImportError.tooManyRegions }

        var zones: [StudioSamplerZone] = []
        var warnings = Set<String>()
        // Cache lightweight metadata per distinct source; avoid opening the
        // same orchestral sample once for every note and velocity zone.
        var audioFrames: [String: UInt32] = [:]
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let roots = [directory] + (samplesRoot.map {
            [$0.resolvingSymlinksInPath().standardizedFileURL]
        } ?? [])
        for region in parsed {
            let p = region.values
            guard let sample = p["sample"], !sample.isEmpty else {
                throw ImportError.invalidRegion(region.line, "missing sample opcode")
            }
            let normalized = sample.replacingOccurrences(of: "\\", with: "/")
            guard !normalized.hasPrefix("/"), !normalized.contains(":"),
                  !normalized.split(separator: "/").contains("..") else {
                throw ImportError.unsafeSamplePath(sample)
            }
            // Each path must remain inside the instrument's folder or an
            // explicitly user-selected sample root, including after
            // resolving symbolic links. Never search the entire filesystem.
            var resolved: URL?
            for root in roots {
                let candidate = root.appendingPathComponent(normalized)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard candidate.path.hasPrefix(root.path + "/") else { continue }
                if (try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    resolved = candidate
                    break
                }
            }
            guard let realFile = resolved else {
                throw ImportError.missingSample(sample)
            }
            let frames: UInt32
            if let cached = audioFrames[realFile.path] {
                frames = cached
            } else {
                // A file with a .wav/.aif/.caf extension is not necessarily
                // decodable audio. Reject it before staging an instrument.
                let audio: AVAudioFile
                do { audio = try AVAudioFile(forReading: realFile) }
                catch { throw ImportError.invalidRegion(
                    region.line, "unsupported or damaged sample: \(sample)") }
                guard (1...2).contains(Int(audio.processingFormat.channelCount)),
                      audio.processingFormat.sampleRate.isFinite,
                      audio.processingFormat.sampleRate > 0,
                      audio.length >= 2 && audio.length <= 500_000_000
                else {
                    throw ImportError.invalidRegion(
                        region.line, "sample is not supported stereo/mono audio: \(sample)")
                }
                frames = UInt32(audio.length)
                audioFrames[realFile.path] = frames
            }
            func note(_ key: String, fallback: Int) throws -> Int {
                guard let raw = p[key] else { return fallback }
                if let n = Int(raw), (0...127).contains(n) { return n }
                let notes = StudioSamplerMappingBuilder.noteNumber(in: URL(fileURLWithPath: raw + ".wav"))
                guard let n = notes else { throw ImportError.invalidRegion(region.line, "invalid \(key)") }
                return n
            }
            func number(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
                guard let raw = p[key] else { return fallback }
                guard let n = Int(raw), range.contains(n) else {
                    throw ImportError.invalidRegion(region.line, "invalid \(key)")
                }
                return n
            }
            let key = try p["key"].map { _ in try note("key", fallback: 60) }
            let root = try note("pitch_keycenter", fallback: key ?? 60)
            let low = try key ?? note("lokey", fallback: 0)
            let high = try key ?? note("hikey", fallback: 127)
            let lowVel = try number("lovel", fallback: 1, range: 0...127)
            let highVel = try number("hivel", fallback: 127, range: 1...127)
            guard low <= high, lowVel <= highVel else {
                throw ImportError.invalidRegion(region.line, "reversed key or velocity range")
            }
            var zone = StudioSamplerZone(sampleURL: realFile, rootNote: UInt8(root),
                lowestNote: UInt8(low), highestNote: UInt8(high),
                lowestVelocity: UInt8(max(1, lowVel)), highestVelocity: UInt8(highVel))
            if let loopMode = p["loop_mode"], loopMode == "loop_continuous" || loopMode == "loop_sustain" {
                if let start = p["loop_start"].flatMap(UInt32.init),
                   let end = p["loop_end"].flatMap(UInt32.init), end < UInt32.max {
                    guard start < end + 1, end + 1 <= frames,
                          end + 1 - start >= 4 else {
                        throw ImportError.invalidRegion(
                            region.line, "sample loop exceeds recording bounds")
                    }
                    zone.loopStartFrame = start
                    zone.loopEndFrame = end + 1 // SFZ end is inclusive; Studio end is exclusive.
                } else {
                    warnings.insert("A looping region has no explicit loop points; its loop was not imported.")
                }
            }
            guard zone.isValid else { throw ImportError.invalidRegion(region.line, "invalid zone or loop") }
            zones.append(zone)
            let supported: Set<String> = ["sample", "key", "lokey", "hikey", "pitch_keycenter",
                "lovel", "hivel", "loop_mode", "loop_start", "loop_end", "default_path"]
            for opcode in p.keys where !supported.contains(opcode) {
                warnings.insert("Unsupported SFZ opcode: \(opcode)")
            }
        }
        let patch = StudioSamplerPatch(zones: zones)
        guard patch.isValid else { throw ImportError.noRegions }
        return Result(patch: patch, warnings: warnings.sorted())
    }

    /// Imports a validated SFZ mapping's samples into Studio-managed storage.
    /// Original SFZ and sample files remain untouched.
    public static func importInstrument(_ url: URL,
                                        into sampleDirectory: URL? = nil,
                                        samplesRoot: URL? = nil) throws -> Result {
        let previewed = try preview(url, samplesRoot: samplesRoot)
        // A single sample may be referenced by many SFZ regions.
        // Copy it once and reuse the managed URL in each mapped zone.
        var sources: [URL] = []
        var positions: [String: Int] = [:]
        for zone in previewed.patch.zones {
            if positions[zone.filePath] == nil {
                positions[zone.filePath] = sources.count
                sources.append(zone.sampleURL)
            }
        }
        let copies = try StudioSamplerSampleLibrary.importFiles(
            sources, into: sampleDirectory)
        var patch = previewed.patch
        for index in patch.zones.indices {
            guard let position = positions[patch.zones[index].filePath] else {
                throw ImportError.unreadable
            }
            patch.zones[index].filePath = copies[position].path
            patch.zones[index].managedFileName = sampleDirectory == nil
                ? StudioSamplerSampleLibrary.managedName(for: copies[position])
                : nil
        }
        return Result(patch: patch, warnings: previewed.warnings)
    }

    private static func parse(_ text: String) -> [Region] {
        // Strip line comments, retaining opcode lines and quoted filenames.
        let lines = text.components(separatedBy: .newlines)
        var control: [String: String] = [:]
        var global: [String: String] = [:]
        var group: [String: String] = [:]
        var regions: [Region] = []
        var section = ""
        let tokenPattern = #"(?:<([A-Za-z_]+)>)|([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s<]+))"#
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        for (lineNumber, original) in lines.enumerated() {
            let line = String(original.prefix(8192))
            let stripped = line.components(separatedBy: "//").first ?? ""
            let ns = stripped as NSString
            for match in regex.matches(in: stripped,
                                       range: NSRange(location: 0, length: ns.length)) {
                if match.range(at: 1).location != NSNotFound {
                    section = ns.substring(with: match.range(at: 1)).lowercased()
                    if section == "group" { group = global }
                    if section == "region" {
                        regions.append(Region(line: lineNumber + 1, values: group))
                    }
                    continue
                }
                let key = ns.substring(with: match.range(at: 2)).lowercased()
                let valueRange = [3, 4, 5].map { match.range(at: $0) }
                    .first { $0.location != NSNotFound }!
                let value = ns.substring(with: valueRange)
                switch section {
                case "control": control[key] = value
                case "global": global[key] = value; group[key] = value
                case "group": group[key] = value
                case "region":
                    if !regions.isEmpty { regions[regions.count - 1].values[key] = value }
                default: break
                }
            }
        }
        return regions.map { region in
            var updated = region
            if let prefix = control["default_path"], let sample = updated.values["sample"] {
                updated.values["sample"] = prefix + sample
            }
            updated.values.removeValue(forKey: "default_path")
            return updated
        }
    }
}
