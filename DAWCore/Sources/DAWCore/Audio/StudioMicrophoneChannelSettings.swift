import Foundation

/// Persisted mic-mixer controls. Optional on StudioVirtualMicrophone so older
/// microphone objects continue to decode without a project migration.
public struct StudioMicrophoneChannelSettings: Codable, Equatable, Sendable {
    public var level: Float
    public var pan: Float
    public var isMuted: Bool
    public var isSolo: Bool

    public init(level: Float = 0.65, pan: Float = 0,
                isMuted: Bool = false, isSolo: Bool = false) {
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
    }

    public var safeLevel: Float {
        level.isFinite ? min(2, max(0, level)) : 0.65
    }
    public var safePan: Float {
        pan.isFinite ? min(1, max(-1, pan)) : 0
    }
}
