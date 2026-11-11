import Foundation

/// An owned-sample reference for Studio's native sampler. Sample data is not
/// embedded in the track JSON; a future portable .studioinstrument package
/// and security-scoped file bookmarks will replace the absolute file path.
public struct StudioSamplerZone: Codable, Equatable, Sendable {
    public var filePath: String
    public var rootNote: UInt8
    public var lowestNote: UInt8
    public var highestNote: UInt8
    public var lowestVelocity: UInt8
    public var highestVelocity: UInt8

    public init(sampleURL: URL, rootNote: UInt8 = 60,
                lowestNote: UInt8 = 0, highestNote: UInt8 = 127,
                lowestVelocity: UInt8 = 1, highestVelocity: UInt8 = 127) {
        self.filePath = sampleURL.path
        self.rootNote = rootNote
        self.lowestNote = lowestNote
        self.highestNote = highestNote
        self.lowestVelocity = lowestVelocity
        self.highestVelocity = highestVelocity
    }

    public var isValid: Bool {
        rootNote <= 127 && lowestNote <= highestNote && highestNote <= 127 &&
        lowestVelocity >= 1 && lowestVelocity <= highestVelocity &&
        highestVelocity <= 127 && !filePath.isEmpty
    }

    public var sampleURL: URL { URL(fileURLWithPath: filePath) }
}

/// Versioned, editable mapping of source audio to MIDI note/velocity ranges.
/// Milestone 1 selects one matching zone per note, favoring the nearest root.
/// Layer blending and streamed sample references will extend this format.
public struct StudioSamplerPatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var zones: [StudioSamplerZone]

    public init(zones: [StudioSamplerZone]) {
        self.zones = zones
    }

    public init(sampleURL: URL, rootNote: UInt8 = 60) {
        self.zones = [StudioSamplerZone(sampleURL: sampleURL, rootNote: rootNote)]
    }

    public var isValid: Bool {
        version == 1 && !zones.isEmpty && zones.count <= 128 &&
        zones.allSatisfy(\.isValid)
    }
}
