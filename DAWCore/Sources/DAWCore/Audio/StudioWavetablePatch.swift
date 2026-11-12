import Foundation

/// Parameter IDs and ranges correspond directly to the original native C ABI.
public enum StudioWavetableParameter: Int32, CaseIterable, Codable, Sendable {
    case osc1Position = 0, osc2Position = 1, osc1Level = 2, osc2Level = 3
    case osc2Detune = 4, attack = 5, decay = 6, sustain = 7, release = 8
    case outputGain = 9, bendRange = 10, lfoRate = 11, lfoDepth = 12
    case velocityPosition = 13, modWheelPosition = 14
    case partial1 = 15, partial2 = 16, partial3 = 17, partial4 = 18
    case partial5 = 19, partial6 = 20, partial7 = 21, partial8 = 22
    case partial9 = 23, partial10 = 24, partial11 = 25, partial12 = 26
    case partial13 = 27, partial14 = 28, partial15 = 29, partial16 = 30

    public static func partial(_ index: Int) -> StudioWavetableParameter? {
        guard (0..<16).contains(index) else { return nil }
        return StudioWavetableParameter(rawValue: Int32(15 + index))
    }
    public var harmonicIndex: Int? {
        rawValue >= 15 ? Int(rawValue - 15) : nil
    }
    public var defaultValue: Float {
        switch self {
        case .osc1Position: return 2
        case .osc2Position: return 0
        case .osc1Level: return 0.65
        case .osc2Level: return 0.2
        case .osc2Detune: return 0
        case .attack: return 0.005
        case .decay: return 0.25
        case .sustain: return 0.7
        case .release: return 0.25
        case .outputGain: return 0.7
        case .bendRange: return 2
        case .lfoRate: return 0.5
        case .lfoDepth, .velocityPosition, .modWheelPosition: return 0
        default: return self == .partial1 ? 1 : 0
        }
    }
    public var range: ClosedRange<Float> {
        switch self {
        case .osc1Position, .osc2Position: return 0...5
        case .osc2Detune: return -24...24
        case .attack, .decay, .release: return 0.001...30
        case .bendRange: return 0...24
        case .lfoRate: return 0.05...20
        case .velocityPosition, .modWheelPosition: return -1...1
        default: return 0...1
        }
    }
    public var logarithmic: Bool {
        switch self {
        case .attack, .decay, .release, .lfoRate: return true
        default: return false
        }
    }
    public var name: String {
        switch self {
        case .osc1Position: return "Wavetable 1"
        case .osc2Position: return "Wavetable 2"
        case .osc1Level: return "Osc 1 Level"
        case .osc2Level: return "Osc 2 Level"
        case .osc2Detune: return "Osc 2 Tune"
        case .attack: return "Attack"
        case .decay: return "Decay"
        case .sustain: return "Sustain"
        case .release: return "Release"
        case .outputGain: return "Output"
        case .bendRange: return "Bend Range"
        case .lfoRate: return "Morph LFO Rate"
        case .lfoDepth: return "Morph LFO Depth"
        case .velocityPosition: return "Velocity → Morph"
        case .modWheelPosition: return "CC1 → Morph"
        default: return "Harmonic \((harmonicIndex ?? 0) + 1)"
        }
    }
    public func valid(_ value: Float) -> Bool {
        value.isFinite && range.contains(value)
    }
    public func position(for value: Float) -> Double {
        let v = Double(min(range.upperBound, max(range.lowerBound, value)))
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        return logarithmic ? log(v / lo) / log(hi / lo) : (v - lo) / (hi - lo)
    }
    public func value(at position: Double) -> Float {
        let t = min(1, max(0, position.isFinite ? position : 0))
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        return Float(logarithmic ? lo * pow(hi / lo, t) : lo + (hi - lo) * t)
    }
    public func displayValue(_ value: Float) -> String {
        switch self {
        case .osc1Position, .osc2Position:
            let labels = ["Sine", "Triangle", "Saw", "Square", "Glass", "Custom"]
            let index = min(5, max(0, Int(value)))
            return value == Float(index) ? labels[index] :
                String(format: "%.2f", value)
        case .attack, .decay, .release:
            return value < 1 ? String(format: "%.0f ms", value * 1000) :
                               String(format: "%.2f s", value)
        case .osc2Detune, .bendRange:
            return String(format: "%.2f st", value)
        case .lfoRate: return String(format: "%.2f Hz", value)
        default: return String(format: "%.2f", value)
        }
    }
}

public struct StudioWavetablePatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var values: [String: Float] = [:]
    public init() {}
    public func value(for parameter: StudioWavetableParameter) -> Float {
        guard let stored = values[String(parameter.rawValue)],
              parameter.valid(stored) else { return parameter.defaultValue }
        return stored
    }
    public mutating func set(_ value: Float, for parameter: StudioWavetableParameter) {
        guard parameter.valid(value) else { return }
        values[String(parameter.rawValue)] = value
    }
    public func validate() -> Bool {
        version == 1 && values.allSatisfy { key, value in
            guard let id = Int32(key),
                  let param = StudioWavetableParameter(rawValue: id) else { return false }
            return param.valid(value)
        }
    }
}
