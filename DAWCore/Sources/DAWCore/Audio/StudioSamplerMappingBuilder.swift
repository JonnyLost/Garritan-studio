import Foundation

/// Predictable, editable first-pass key and velocity mapping.
/// This is filename-based metadata mapping, not acoustic pitch analysis.
/// Never reads or modifies the sample audio.
public enum StudioSamplerMappingBuilder {
    public enum MappingError: Error, LocalizedError {
        case emptySelection
        case tooManySamples
        case tooManyArticulations

        public var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "Choose at least one sample."
            case .tooManySamples:
                return "The current sampler supports at most 128 sample zones per instrument."
            case .tooManyArticulations:
                return "Studio Sampler supports at most 15 additional articulations."
            }
        }
    }

    private struct Candidate {
        var url: URL
        var root: Int
        var velocity: Int?
        var roundRobin: UInt8?
        var isRelease: Bool
        var articulation: String?
    }

    /// Analyze filenames without changing the recordings. Each articulation
    /// gets its own key-range map, so a sparse pizzicato library is not
    /// constrained by the sustain recordings' root-note layout.
    public static func makePatch(urls: [URL]) throws -> StudioSamplerPatch {
        guard !urls.isEmpty else { throw MappingError.emptySelection }
        guard urls.count <= 128 else { throw MappingError.tooManySamples }

        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let names = Array(Set(sorted.compactMap { articulationHint(in: $0) })).sorted()
        guard names.count <= 15 else { throw MappingError.tooManyArticulations }
        let articulationIDs = Dictionary(uniqueKeysWithValues:
            names.enumerated().map { ($0.element, UInt8($0.offset + 1)) })
        let candidates = sorted.enumerated().map { index, url in
            Candidate(url: url,
                      root: noteNumber(in: url) ?? min(127, 60 + index),
                      velocity: velocityHint(in: url),
                      roundRobin: roundRobinHint(in: url),
                      isRelease: releaseHint(in: url),
                      articulation: articulationHint(in: url))
        }
        var zones: [StudioSamplerZone] = []
        let groups: [String?] = [nil] + names.map(Optional.some)

        for articulation in groups {
            let subset = candidates.filter { $0.articulation == articulation }
            guard !subset.isEmpty else { continue }
            let roots = Array(Set(subset.map(\.root))).sorted()
            for (rootIndex, root) in roots.enumerated() {
                let lowestKey = rootIndex == 0 ? 0 : (roots[rootIndex - 1] + root) / 2 + 1
                let highestKey = rootIndex + 1 == roots.count
                    ? 127 : (root + roots[rootIndex + 1]) / 2

                for isRelease in [false, true] {
                    let group = subset.filter {
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

                    // Files explicitly tagged rr1/rr2 share their velocity
                    // layer; attack and release recordings are separate.
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
                            zone.articulationID = articulation.flatMap { articulationIDs[$0] }
                            zones.append(zone)
                        }
                    }
                }
            }
        }
        var patch = StudioSamplerPatch(zones: zones)
        if !names.isEmpty {
            patch.articulations = names.enumerated().map { index, name in
                StudioSamplerArticulation(id: UInt8(index + 1),
                                          name: name,
                                          keyswitchNote: UInt8(24 + index))
            }
            patch.defaultKeyswitchNote = 23
        }
        return patch
    }

    /// Merge a new import without overwriting edits on the current instrument.
    /// Match articulation names first, allocate stable IDs/keyswitches for new
    /// names, and fail before mutating the existing mapping if limits are hit.
    public static func append(_ imported: StudioSamplerPatch,
                              to existing: StudioSamplerPatch) throws -> StudioSamplerPatch {
        guard existing.zones.count + imported.zones.count <= 128 else {
            throw MappingError.tooManySamples
        }
        var merged = existing
        var articulations = merged.articulations ?? []
        var idMap: [UInt8: UInt8] = [0: 0]
        let incoming = imported.articulations ?? []
        var reserved = Set(articulations.map(\.keyswitchNote))
        if let note = merged.defaultKeyswitchNote { reserved.insert(note) }
        for item in incoming {
            if let match = articulations.first(where: {
                $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame
            }) {
                idMap[item.id] = match.id
                continue
            }
            let ids = Set(articulations.map(\.id))
            guard let id = (1...15).map(UInt8.init).first(where: { !ids.contains($0) }),
                  let key = (24...127).map(UInt8.init).first(where: { !reserved.contains($0) })
            else { throw MappingError.tooManyArticulations }
            articulations.append(StudioSamplerArticulation(id: id,
                                              name: item.name, keyswitchNote: key))
            idMap[item.id] = id
            reserved.insert(key)
        }
        var addedZones = imported.zones
        for index in addedZones.indices {
            addedZones[index].articulationID =
                idMap[addedZones[index].articulationID ?? 0].flatMap { $0 == 0 ? nil : $0 }
        }
        merged.zones.append(contentsOf: addedZones)
        if !articulations.isEmpty {
            merged.articulations = articulations
            if merged.defaultKeyswitchNote == nil {
                let keys = Set(articulations.map(\.keyswitchNote))
                merged.defaultKeyswitchNote = (0...127).map(UInt8.init)
                    .first(where: { !keys.contains($0) })
            }
        }
        guard merged.isValid else { throw MappingError.tooManyArticulations }
        return merged
    }

    /// C4 = MIDI 60. Recognizes C4, C#4, Db4, Bb3 in filename tokens.
    public static func noteNumber(in url: URL) -> Int? {
        let tokens = filenameTokens(url)
        let pattern = #"^([a-gA-G])([#b]?)([0-9])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let offsets = ["c": 0, "d": 2, "e": 4, "f": 5,
                       "g": 7, "a": 9, "b": 11]
        for token in tokens {
            let lower = token.lowercased()
            for prefix in ["midi", "note", "n"] where lower.hasPrefix(prefix) {
                if let value = Int(lower.dropFirst(prefix.count)), (0...127).contains(value) {
                    return value
                }
            }
        }
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

    /// Common orchestral articulation tokens. A plain sustain recording
    /// remains the default articulation, not an extra keyswitch group.
    public static func articulationHint(in url: URL) -> String? {
        let aliases: [String: String] = [
            "legato": "Legato", "leg": "Legato",
            "staccato": "Staccato", "stacc": "Staccato",
            "pizzicato": "Pizzicato", "pizz": "Pizzicato",
            "spiccato": "Spiccato", "spicc": "Spiccato",
            "tremolo": "Tremolo", "trem": "Tremolo",
            "harmonics": "Harmonics", "harmonic": "Harmonics",
            "marcato": "Marcato", "marc": "Marcato",
            "sforzando": "Sforzando", "sfz": "Sforzando",
            "flutter": "Flutter Tongue", "fluttertongue": "Flutter Tongue",
            "trill": "Trill", "trills": "Trill",
            "collegno": "Col Legno", "sulponte": "Sul Ponticello"
        ]
        return filenameTokens(url).compactMap { aliases[$0.lowercased()] }.first
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
