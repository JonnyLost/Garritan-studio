import Foundation

/// Listener placement for Studio's original native orchestral reverb.
/// This is a controlled perceptual approximation, not a measured microphone
/// array, physical propagation model, or a replacement for track positioning.
public enum StudioMicrophonePerspective: String, Codable, CaseIterable, Identifiable, Sendable {
    case conductor
    case mainPair
    case audience

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .conductor: return "Conductor / Close"
        case .mainPair: return "Main Stereo Pair"
        case .audience: return "Audience / Distant"
        }
    }

    /// Relative direct signal gain when the original native room is enabled.
    public var directLevel: Float {
        switch self {
        case .conductor: return 1.0
        case .mainPair: return 0.86
        case .audience: return 0.70
        }
    }

    /// Extra travel time on per-track reflected paths (not the dry source).
    public var additionalReflectionMilliseconds: Double {
        switch self {
        case .conductor: return 0
        case .mainPair: return 3.5
        case .audience: return 8
        }
    }

    public var earlyReflectionLevel: Float {
        switch self {
        case .conductor: return 1.0
        case .mainPair: return 1.08
        case .audience: return 1.16
        }
    }

    /// Stable AU indexed parameter mapping. Do not change ordering without
    /// a migration plan; project persistence uses the raw string, not index.
    public var parameterIndex: Int {
        switch self {
        case .conductor: return 0
        case .mainPair: return 1
        case .audience: return 2
        }
    }
}

/// Entirely original virtual stereo-microphone controls.
/// Default conductor + unity width preserves prior native routing behavior.
public struct StudioVirtualMicrophoneSettings: Codable, Equatable, Sendable {
    public var perspective: StudioMicrophonePerspective
    /// 0 = mono/coincident early field; 1 = default; 1.5 = enhanced width.
    public var stereoWidth: Float

    public init(perspective: StudioMicrophonePerspective = .conductor,
                stereoWidth: Float = 1) {
        self.perspective = perspective
        self.stereoWidth = stereoWidth
    }

    public var safeWidth: Float {
        stereoWidth.isFinite ? max(0, min(1.5, stereoWidth)) : 1
    }
}
