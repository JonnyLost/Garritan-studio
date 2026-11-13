import Foundation

/// A recording prepared in Studio's Instrument Factory. The musical mapping
/// comes from explicit labels chosen by the composer, not guessed filenames.
public struct StudioSamplerFactoryTake: Sendable, Identifiable {
    public let id: UUID
    public var source: URL
    public var rootNote: UInt8
    public var velocity: UInt8
    public var microphoneID: UInt8
    public var articulation: String
    public var releaseTrigger: Bool
    public var legatoFromNote: UInt8?

    public init(source: URL, rootNote: UInt8 = 60, velocity: UInt8 = 96,
                microphoneID: UInt8 = 0, articulation: String = "Sustain",
                releaseTrigger: Bool = false, legatoFromNote: UInt8? = nil,
                id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.rootNote = rootNote
        self.velocity = velocity
        self.microphoneID = microphoneID
        self.articulation = articulation
        self.releaseTrigger = releaseTrigger
        self.legatoFromNote = legatoFromNote
    }

    public var normalizedArticulation: String {
        let name = articulation.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.lowercased() == "sustain" ||
            name.lowercased() == "default" ? "" : name
    }

    public var isValid: Bool {
        rootNote <= 127 && (1...127).contains(velocity) &&
        microphoneID < 4 && articulation.count <= 48 &&
        (legatoFromNote == nil || (
            legatoFromNote! <= 127 && legatoFromNote! != rootNote &&
            !releaseTrigger))
    }
}

/// Build genuine velocity and key maps from explicit capture notes, then
/// install app-owned sample copies transactionally. This is pure mapping +
/// background file I/O; no changes to the real-time renderer.
public enum StudioSamplerInstrumentFactory {
    public enum FactoryError: Error, LocalizedError {
        case emptySelection
        case tooManyZones
        case tooManyArticulations
        case invalidTake

        public var errorDescription: String? {
            switch self {
            case .emptySelection: return "Record or import at least one sample first."
            case .tooManyZones: return "A Studio sampler instrument supports at most 128 zones."
            case .tooManyArticulations: return "At most 15 custom articulations are supported."
            case .invalidTake: return "A captured recording has invalid note or articulation labels."
            }
        }
    }

    /// Returns an editable patch. No audio node is created and nothing is
    /// applied to a track until the mapping editor commits it.
    public static func assemble(_ takes: [StudioSamplerFactoryTake],
                                extending existing: StudioSamplerPatch? = nil,
                                sampleDirectory: URL? = nil) throws -> StudioSamplerPatch {
        guard !takes.isEmpty else { throw FactoryError.emptySelection }
        guard takes.count + (existing?.zones.count ?? 0) <= 128 else {
            throw FactoryError.tooManyZones
        }
        guard takes.allSatisfy(\.isValid) else { throw FactoryError.invalidTake }
        let names = Array(Set(takes.map(\.normalizedArticulation)
            .filter { !$0.isEmpty })).sorted()
        guard names.count <= 15 else { throw FactoryError.tooManyArticulations }
        let ids = Dictionary(uniqueKeysWithValues:
            names.enumerated().map { ($0.element, UInt8($0.offset + 1)) })

        let ordered = takes.sorted { a, b in
            if a.normalizedArticulation != b.normalizedArticulation {
                return a.normalizedArticulation < b.normalizedArticulation
            }
            if a.microphoneID != b.microphoneID { return a.microphoneID < b.microphoneID }
            if a.rootNote != b.rootNote { return a.rootNote < b.rootNote }
            if a.velocity != b.velocity { return a.velocity < b.velocity }
            return a.source.lastPathComponent < b.source.lastPathComponent
        }

        var zones: [StudioSamplerZone] = []
        for take in ordered {
            let related = ordered.filter {
                $0.normalizedArticulation == take.normalizedArticulation &&
                $0.microphoneID == take.microphoneID &&
                $0.legatoFromNote == take.legatoFromNote &&
                $0.releaseTrigger == take.releaseTrigger
            }
            let roots = Array(Set(related.map(\.rootNote))).sorted()
            let index = roots.firstIndex(of: take.rootNote)!
            let lowKey: UInt8 = take.legatoFromNote != nil ? take.rootNote :
                index == 0 ? 0 : UInt8((Int(roots[index - 1]) + Int(take.rootNote)) / 2 + 1)
            let highKey: UInt8 = take.legatoFromNote != nil ? take.rootNote :
                index + 1 == roots.count ? 127 :
                UInt8((Int(take.rootNote) + Int(roots[index + 1])) / 2)
            let levels = Array(Set(related.filter { $0.rootNote == take.rootNote }
                .map(\.velocity))).sorted()
            let layer = levels.firstIndex(of: take.velocity)!
            let lower = layer == 0 ? 1 :
                (Int(levels[layer - 1]) + Int(take.velocity)) / 2 + 1
            let upper = layer + 1 == levels.count ? 127 :
                (Int(take.velocity) + Int(levels[layer + 1])) / 2
            var zone = StudioSamplerZone(
                sampleURL: take.source,
                rootNote: take.rootNote,
                lowestNote: lowKey,
                highestNote: highKey,
                lowestVelocity: UInt8(lower),
                highestVelocity: UInt8(upper))
            zone.articulationID = ids[take.normalizedArticulation]
            zone.microphoneID = take.microphoneID == 0 ? nil : take.microphoneID
            zone.isReleaseTrigger = take.releaseTrigger ? true : nil
            zone.legatoFromNote = take.legatoFromNote
            zones.append(zone)
        }
        var patch = StudioSamplerPatch(zones: zones)
        if !names.isEmpty {
            patch.articulations = names.enumerated().map {
                StudioSamplerArticulation(id: UInt8($0.offset + 1),
                                          name: $0.element,
                                          keyswitchNote: UInt8(24 + $0.offset))
            }
            patch.defaultKeyswitchNote = 23
        }
        let micIDs = Array(Set(takes.map(\.microphoneID))).sorted()
        if micIDs.contains(where: { $0 > 0 }) {
            let labels = ["Close", "Main / Tree", "Room", "Spot"]
            patch.microphones = micIDs.map {
                StudioSamplerMicrophone(id: $0, name: labels[Int($0)])
            }
        }
        if takes.contains(where: { $0.legatoFromNote != nil }) {
            patch.legatoEnabled = true
            patch.legatoCrossfadeMilliseconds = 40
        }
        guard patch.isValid else { throw FactoryError.invalidTake }

        // Use existing keyswitch merge logic before copying any files.
        let combined = try existing.map {
            try StudioSamplerMappingBuilder.append(patch, to: $0)
        } ?? patch
        let copied = try StudioSamplerSampleLibrary.importFiles(
            zones.map(\.sampleURL), into: sampleDirectory)
        var installed = combined
        let offset = existing?.zones.count ?? 0
        for index in copied.indices {
            installed.zones[offset + index].filePath = copied[index].path
            installed.zones[offset + index].managedFileName =
                StudioSamplerSampleLibrary.managedName(for: copied[index],
                                                       in: sampleDirectory)
        }
        guard installed.isValid else { throw FactoryError.invalidTake }
        return installed
    }
}
