import Foundation

/// Stable IDs from StudioFMDSP.h. Stored as numeric keys for forward-compatible
/// per-track persistence; these values are independent of UI ordering.
public enum StudioFMParameter: Int32, CaseIterable, Codable, Sendable {
    case algorithm = 0
    case feedback = 1
    case outputGain = 2
    case bendRange = 3
    case op1Ratio = 4
    case op1Level = 5
    case op1Attack = 6
    case op1Decay = 7
    case op1Sustain = 8
    case op1Release = 9
    case op2Ratio = 10
    case op2Level = 11
    case op2Attack = 12
    case op2Decay = 13
    case op2Sustain = 14
    case op2Release = 15
    case op3Ratio = 16
    case op3Level = 17
    case op3Attack = 18
    case op3Decay = 19
    case op3Sustain = 20
    case op3Release = 21
    case op4Ratio = 22
    case op4Level = 23
    case op4Attack = 24
    case op4Decay = 25
    case op4Sustain = 26
    case op4Release = 27
    // Appended parameter identifiers preserve old Studio FM projects.
    case velocityBrightness = 28
    case modTarget = 29
    case modDepth = 30
    case modRate = 31

    public static func op(_ index: Int, _ control: StudioFMOperatorControl) -> StudioFMParameter? {
        guard (0..<4).contains(index) else { return nil }
        return StudioFMParameter(rawValue: Int32(4 + 6 * index) + control.rawValue)
    }

    public var operatorIndex: Int? {
        (4...27).contains(rawValue) ? Int((rawValue - 4) / 6) : nil
    }

    public var operatorControl: StudioFMOperatorControl? {
        (4...27).contains(rawValue)
            ? StudioFMOperatorControl(rawValue: (rawValue - 4) % 6) : nil
    }

    public var defaultValue: Float {
        let global: [Float] = [0, 0, 0.65, 2]
        if rawValue < 4 { return global[Int(rawValue)] }
        switch self {
        case .velocityBrightness: return 0
        case .modTarget: return 0
        case .modDepth: return 0.5
        case .modRate: return 5
        default: break
        }
        let defaults: [[Float]] = [
            [1, 0.8, 0.005, 0.25, 0.75, 0.22],
            [2, 0.30, 0.005, 0.28, 0.64, 0.18],
            [3, 0.14, 0.005, 0.20, 0.55, 0.17],
            [4, 0.00, 0.005, 0.18, 0.55, 0.13]
        ]
        return defaults[operatorIndex!][Int(operatorControl!.rawValue)]
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .algorithm: return 0...3
        case .feedback, .outputGain, .velocityBrightness, .modDepth: return 0...1
        case .modTarget: return 0...1
        case .modRate: return 0.1...20
        case .bendRange: return 0...24
        default:
            switch operatorControl! {
            case .ratio: return 0.125...16
            case .level, .sustain: return 0...1
            case .attack, .decay, .release: return 0.001...30
            }
        }
    }

    public var logarithmic: Bool {
        if self == .modRate { return true }
        switch operatorControl {
        case .ratio, .attack, .decay, .release: return true
        default: return false
        }
    }

    public var name: String {
        switch self {
        case .algorithm: return "Algorithm"
        case .feedback: return "Feedback"
        case .outputGain: return "Output"
        case .bendRange: return "Bend Range"
        case .velocityBrightness: return "Velocity Brightness"
        case .modTarget: return "Wheel Target"
        case .modDepth: return "Wheel Depth"
        case .modRate: return "Vibrato Rate"
        default: return operatorControl!.title
        }
    }

    public func valid(_ value: Float) -> Bool {
        value.isFinite && range.contains(value) &&
        ((self != .algorithm && self != .modTarget) ||
         value.rounded(.towardZero) == value)
    }

    public func value(at position: Double) -> Float {
        let t = min(1, max(0, position.isFinite ? position : 0))
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        return Float(logarithmic ? lo * pow(hi / lo, t) : lo + (hi - lo) * t)
    }

    public func position(for value: Float) -> Double {
        let clamped = Double(min(range.upperBound, max(range.lowerBound, value)))
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        return logarithmic ? log(clamped / lo) / log(hi / lo)
                           : (clamped - lo) / (hi - lo)
    }

    public func displayValue(_ value: Float) -> String {
        switch self {
        case .algorithm: return StudioFMAlgorithm(rawValue: Int(value))?.name ?? "Unknown"
        case .bendRange: return String(format: "±%.1f st", value)
        case .modTarget: return value == 0 ? "Vibrato" : "Brightness"
        case .modRate: return String(format: "%.2f Hz", value)
        default:
            if operatorControl == .ratio { return String(format: "%.3f ×", value) }
            if operatorControl == .attack || operatorControl == .decay ||
               operatorControl == .release {
                return value < 1 ? String(format: "%.0f ms", value * 1000)
                                 : String(format: "%.2f s", value)
            }
            return String(format: "%.2f", value)
        }
    }
}

public enum StudioFMOperatorControl: Int32, CaseIterable, Sendable {
    case ratio = 0, level = 1, attack = 2, decay = 3, sustain = 4, release = 5

    public var title: String {
        switch self {
        case .ratio: return "Ratio"
        case .level: return "Level"
        case .attack: return "Attack"
        case .decay: return "Decay"
        case .sustain: return "Sustain"
        case .release: return "Release"
        }
    }
}

public enum StudioFMAlgorithm: Int, CaseIterable, Identifiable, Sendable {
    case serial = 0
    case split = 1
    case stack = 2
    case parallel = 3

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .serial: return "Serial"
        case .split: return "Split"
        case .stack: return "Stack"
        case .parallel: return "Parallel"
        }
    }

    public var diagram: String {
        switch self {
        case .serial: return "4 → 3 → 2 → 1 → OUT"
        case .split: return "4 → 3 ↘ OUT   /   2 → 1 ↗ OUT"
        case .stack: return "(4 + 3 + 2) → 1 → OUT"
        case .parallel: return "(1 + 2 + 3 + 4) → OUT"
        }
    }

    public var description: String {
        switch self {
        case .serial: return "Four operators in a modulation chain; classic bright FM."
        case .split: return "Two parallel FM voices: 4 modulates 3, and 2 modulates 1."
        case .stack: return "Three modulators shape operator 1 for complex spectra."
        case .parallel: return "Four independent sine voices; additive-like harmonics."
        }
    }
}

public struct StudioFMPatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var values: [String: Float] = [:]

    public init() {}

    public func value(for parameter: StudioFMParameter) -> Float {
        values[String(parameter.rawValue)] ?? parameter.defaultValue
    }

    public mutating func set(_ value: Float, for parameter: StudioFMParameter) {
        guard parameter.valid(value) else { return }
        values[String(parameter.rawValue)] = value
    }

    public func validate() -> Bool {
        version == 1 && values.allSatisfy { key, value in
            guard let id = Int32(key), let p = StudioFMParameter(rawValue: id) else {
                return false
            }
            return p.valid(value)
        }
    }
}
