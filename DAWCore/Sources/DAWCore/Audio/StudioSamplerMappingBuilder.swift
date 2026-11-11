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
                      velocity: velocityHint(in: url))
        }
        let roots = Array(Set(candidates.map(\.root))).sorted()
        var zones: [StudioSamplerZone] = []

        for (rootIndex, root) in roots.enumerated() {
            let lowestKey = rootIndex == 0 ? 0 : (roots[rootIndex - 1] + root) / 2 + 1
            let highestKey = rootIndex + 1 == roots.count
                ? 127 : (root + roots[rootIndex + 1]) / 2
            let group = candidates.filter { $0.root == root }.sorted { left, right in
                if (left.velocity ?? 64) != (right.velocity ?? 64) {
                    return (left.velocity ?? 64) < (right.velocity ?? 64)
                }
                return left.url.lastPathComponent.localizedStandardCompare(
                    right.url.lastPathComponent
                ) == .orderedAscending
            }

            for (index, candidate) in group.enumerated() {
                // Each imported recording gets an audible, non-overlapping
                // velocity range. User can refine or overlap ranges in the editor.
                // With >127 recordings on one root, allow the smallest
                // possible 1-point overlap rather than generating empty
                // ranges that make the entire instrument invalid.
                let lowerVelocity = min(127, 1 + (index * 127) / group.count)
                let upperVelocity = max(lowerVelocity, ((index + 1) * 127) / group.count)
                zones.append(StudioSamplerZone(
                    sampleURL: candidate.url,
                    rootNote: UInt8(root),
                    lowestNote: UInt8(lowestKey),
                    highestNote: UInt8(highestKey),
                    lowestVelocity: UInt8(lowerVelocity),
                    highestVelocity: UInt8(upperVelocity)
                ))
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

    private static func filenameTokens(_ url: URL) -> [String] {
        url.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: " _-."))
            .filter { !$0.isEmpty }
    }
}
