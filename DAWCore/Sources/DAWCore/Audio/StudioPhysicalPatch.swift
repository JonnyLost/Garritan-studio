import Foundation

/// Append-only IDs shared with StudioPhysicalDSP.h. Older Synth sound
/// documents retain all previous layer and parameter identities.
public enum StudioPhysicalParameter: Int32, Codable, CaseIterable, Sendable {
    case model = 0
    case brightness = 1, damping = 2, position = 3, bodyMix = 4
    case release = 5, gain = 6, pickHardness = 7, stiffness = 8
    case bodySize = 9, bowPressure = 10, bowSpeed = 11, bowNoise = 12
    case breath = 13, reedStiffness = 14, airNoise = 15, bore = 16
    case percussionHardness = 17, percussionDecay = 18
    case percussionInharmonicity = 19, percussionAttackNoise = 20

    public var name: String {
        switch self {
        case .model: return "Model"
        case .brightness: return "Brightness"
        case .damping: return "String Damping"
        case .position: return "Contact Position"
        case .bodyMix: return "Body Resonance"
        case .release: return "Release"
        case .gain: return "Output"
        case .pickHardness: return "Pick / Hammer Hardness"
        case .stiffness: return "String Stiffness"
        case .bodySize: return "Body Size"
        case .bowPressure: return "Bow Pressure"
        case .bowSpeed: return "Bow Speed"
        case .bowNoise: return "Bow Texture"
        case .breath: return "Breath Pressure"
        case .reedStiffness: return "Reed / Lip Stiffness"
        case .airNoise: return "Air Noise"
        case .bore: return "Bore Tone"
        case .percussionHardness: return "Striker Hardness"
        case .percussionDecay: return "Resonance Decay"
        case .percussionInharmonicity: return "Inharmonicity"
        case .percussionAttackNoise: return "Strike Noise"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .model: return 0...7
        case .position: return 0.05...0.95
        case .release: return 0.01...4
        default: return 0...1
        }
    }

    public var defaultValue: Float {
        switch self {
        case .model: return 0
        case .brightness: return 0.55
        case .damping: return 0.7
        case .position: return 0.25
        case .bodyMix: return 0.25
        case .release: return 0.2
        case .gain: return 0.5
        case .pickHardness: return 0.45
        case .stiffness: return 0.15
        case .bodySize: return 0.5
        case .bowPressure: return 0.55
        case .bowSpeed: return 0.65
        case .bowNoise: return 0.12
        case .breath: return 0.65
        case .reedStiffness: return 0.55
        case .airNoise: return 0.12
        case .bore: return 0.5
        case .percussionHardness: return 0.5
        case .percussionDecay: return 0.55
        case .percussionInharmonicity: return 0.8
        case .percussionAttackNoise: return 0.18
        }
    }

    public var isContinuous: Bool { self != .model }

    public func valid(_ value: Float) -> Bool {
        value.isFinite && range.contains(value) &&
            (self != .model || value.rounded() == value)
    }

    public func position(for value: Float) -> Double {
        let range = range
        let v = min(range.upperBound, max(range.lowerBound, value))
        if self == .release {
            return log(Double(v / range.lowerBound)) /
                log(Double(range.upperBound / range.lowerBound))
        }
        return Double((v - range.lowerBound) /
                      (range.upperBound - range.lowerBound))
    }

    public func value(at position: Double) -> Float {
        let t = min(1, max(0, position.isFinite ? position : 0))
        let range = range
        if self == .release {
            return Float(Double(range.lowerBound) *
                         pow(Double(range.upperBound / range.lowerBound), t))
        }
        return Float(Double(range.lowerBound) +
                     (Double(range.upperBound) - Double(range.lowerBound)) * t)
    }

    public func displayValue(_ value: Float) -> String {
        switch self {
        case .model: return StudioPhysicalModel(rawValue: Int32(value))?.title ?? "Unknown"
        case .release:
            return value < 1 ? String(format: "%.0f ms", value * 1000) :
                String(format: "%.2f s", value)
        case .position:
            return String(format: "%.0f%%", value * 100)
        default:
            return String(format: "%.0f%%", value * 100)
        }
    }
}

public enum StudioPhysicalModel: Int32, Codable, CaseIterable, Identifiable, Sendable {
    case plucked = 0, struck = 1, bowed = 2, reed = 3, brass = 4
    case mallet = 5, bell = 6, membrane = 7

    public var id: Int32 { rawValue }
    public var title: String {
        switch self {
        case .plucked: return "Plucked String"
        case .struck: return "Struck String"
        case .bowed: return "Bowed String"
        case .reed: return "Reed Wind"
        case .brass: return "Brass"
        case .mallet: return "Mallet"
        case .bell: return "Bell"
        case .membrane: return "Membrane"
        }
    }
}

public struct StudioPhysicalPatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var values: [String: Float] = [:]

    public init() {}

    public var model: StudioPhysicalModel {
        StudioPhysicalModel(rawValue: Int32(value(for: .model))) ?? .plucked
    }

    public func value(for parameter: StudioPhysicalParameter) -> Float {
        guard let stored = values[String(parameter.rawValue)],
              parameter.valid(stored) else { return parameter.defaultValue }
        return stored
    }

    public mutating func set(_ value: Float, for parameter: StudioPhysicalParameter) {
        guard parameter.valid(value) else { return }
        values[String(parameter.rawValue)] = value
    }

    public func validate() -> Bool {
        version == 1 && values.allSatisfy { key, value in
            guard let id = Int32(key),
                  let parameter = StudioPhysicalParameter(rawValue: id) else {
                return false
            }
            return parameter.valid(value)
        }
    }
}
