import Foundation

/// Predictable, editable first-pass key and velocity mapping.
/// This is filename-based metadata mapping, not acoustic pitch analysis.
/// Never reads or modifies the sample audio.
public enum StudioSamplerMappingBuilder {
    public enum MappingError: Error, LocalizedError {
        case emptySelection
        case tooManySamples

        public var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "Choose at least one sample."
            case .tooManySamples:
                return "The current sampler supports at most 128 sample zones per instrument."
            }
        }
    }

    private struct Candidate {
        var url: URL
        var root: Int
        var velocity: Int?
        var roundRobin: UInt8?
        var isRelease: Bool
    }

    public static func makePatch(urls: [URL]) throws -> StudioSamplerPatch {
        guard !urls.isEmpty else { throw MappingError.emptySelection }
        guard urls.count <= 128 else { throw MappingError.tooManySamples }

        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let candidates = sorted.enumerated().map { index, url in
            Candidate(url: url,
                      root: noteNumber(in: url) ?? min(127, 60 + index),
                      velocity: velocityHint(in: url),
                      roundRobin: roundRobinHint(in: url),
                      isRelease: releaseHint(in: url))
        }
        let roots = Array(Set(candidates.map(\.root))).sorted()
        var zones: [StudioSamplerZone] = []

        for (rootIndex, root) in roots.enumerated() {
            let lowestKey = rootIndex == 0 ? 0 : (roots[rootIndex - 1] + root) / 2 + 1
            let highestKey = rootIndex + 1 == roots.count
                ? 127 : (root + roots[rootIndex + 1]) / 2

            // Attack and release recordings are mapped independently so
            // one release tail can serve every velocity without stealing
            // a band from sustain samples. Explicit RR takes share a band.
            for isRelease in [false, true] {
                let group = candidates.filter {
                    $0.root == root && $0.isRelease == isRelease
                }.sorted { left, right in
                    if (left.velocity ?? 64) != (right.velocity ?? 64) {
                        return (left.velocity ?? 64) < (right.velocity ?? 64)
                    }
                    return left.url.lastPathComponent.localizedStandardCompare(
                        right.url.lastPathComponent
                    ) == .orderedAscending
                }
                guard !group.isEmpty else { continue }
                var bands: [[Candidate]] = []
                for candidate in group {
                    if candidate.roundRobin != nil,
                       let last = bands.indices.last,
                       let first = bands[last].first,
                       first.roundRobin != nil &&
                       (first.velocity ?? 64) == (candidate.velocity ?? 64) {
                        bands[last].append(candidate)
                    } else {
                        bands.append([candidate])
                    }
                }
                for (index, band) in bands.enumerated() {
                    let low = min(127, 1 + (index * 127) / bands.count)
                    let high = max(low, (index + 1) * 127 / bands.count)
                    for candidate in band {
                        var zone = StudioSamplerZone(
                            sampleURL: candidate.url,
                            rootNote: UInt8(root),
                            lowestNote: UInt8(lowestKey),
                            highestNote: UInt8(highestKey),
                            lowestVelocity: UInt8(low),
                            highestVelocity: UInt8(high)
                        )
                        zone.roundRobinIndex = candidate.roundRobin
                        zone.isReleaseTrigger = candidate.isRelease ? true : nil
                        zones.append(zone)
                    }
                }
            }
        }
        return StudioSamplerPatch(zones: zones)
    }

    /// C4 = MIDI 60. Recognizes C4, C#4, Db4, Bb3 in filename tokens.
    public static func noteNumber(in url: URL) -> Int? {
        let tokens = filenameTokens(url)
        let pattern = #"^([a-gA-G])([#b]?)([0-9])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let offsets = ["c": 0, "d": 2, "e": 4, "f": 5,
                       "g": 7, "a": 9, "b": 11]
        for token in tokens {
            let name = token as NSString
            guard let match = regex.firstMatch(
                in: token, range: NSRange(location: 0, length: name.length)
            ), match.range.location == 0 else { continue }
            let letter = name.substring(with: match.range(at: 1)).lowercased()
            let accidental = name.substring(with: match.range(at: 2))
            guard let octave = Int(name.substring(with: match.range(at: 3))),
                  let semitone = offsets[letter] else { continue }
            let shift = accidental == "#" ? 1 : accidental == "b" ? -1 : 0
            let midi = (octave + 1) * 12 + semitone + shift
            if (0...127).contains(midi) { return midi }
        }
        return nil
    }

    public static func velocityHint(in url: URL) -> Int? {
        let levels: [String: Int] = [
            "ppp": 15, "pp": 32, "p": 48, "mp": 63,
            "mf": 80, "f": 96, "ff": 112, "fff": 127
        ]
        for token in filenameTokens(url) {
            let lower = token.lowercased()
            if let level = levels[lower] { return level }
            for prefix in ["velocity", "vel", "v"] where lower.hasPrefix(prefix) {
                let remainder = lower.dropFirst(prefix.count)
                if let value = Int(remainder), (1...127).contains(value) {
                    return value
                }
            }
        }
        return nil
    }

    /// rr1...rr8, take1...take8 and alt1...alt8 map to 0...7.
    /// These are metadata hints, not a change to the imported recording.
    public static func roundRobinHint(in url: URL) -> UInt8? {
        for token in filenameTokens(url) {
            let lower = token.lowercased()
            for prefix in ["roundrobin", "take", "alt", "rr"]
                where lower.hasPrefix(prefix) {
                let suffix = lower.dropFirst(prefix.count)
                if let index = Int(suffix), (1...8).contains(index) {
                    return UInt8(index - 1)
                }
            }
        }
        return nil
    }

    public static func releaseHint(in url: URL) -> Bool {
        filenameTokens(url).contains {
            ["release", "rel", "noteoff"].contains($0.lowercased())
        }
    }

    private static func filenameTokens(_ url: URL) -> [String] {
        url.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: " _-."))
            .filter { !$0.isEmpty }
    }
}
