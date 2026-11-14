import Foundation

/// Persisted mic-mixer controls. Optional on StudioVirtualMicrophone so older
/// microphone objects continue to decode without a project migration.
public struct StudioMicrophoneChannelSettings: Codable, Equatable, Sendable {
    public var level: Float
    public var pan: Float
    public var isMuted: Bool
    public var isSolo: Bool
    /// Optional for backward-compatible decoding of old mic-mixer projects.
    /// Signed monitor correction, in milliseconds, applied to every source
    /// captured by this capsule. Does not alter the physical source positions.
    public var alignmentMilliseconds: Float?

    public init(level: Float = 0.65, pan: Float = 0,
                isMuted: Bool = false, isSolo: Bool = false,
                alignmentMilliseconds: Float? = nil) {
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.alignmentMilliseconds = alignmentMilliseconds
    }

    public var safeLevel: Float {
        level.isFinite ? min(2, max(0, level)) : 0.65
    }
    /// +-20ms limit prevents extreme accidental shifts in phase-critical arrays.
    public var safeAlignmentMilliseconds: Float {
        guard let alignmentMilliseconds, alignmentMilliseconds.isFinite else { return 0 }
        return min(20, max(-20, alignmentMilliseconds))
    }
    public var safePan: Float {
        pan.isFinite ? min(1, max(-1, pan)) : 0
    }
}
