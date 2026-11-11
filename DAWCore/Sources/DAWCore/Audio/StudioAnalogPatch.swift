import Foundation

/// Stable, versioned parameter identifiers for Studio's original C++ analog DSP.
/// Keep the raw values in sync with StudioAnalogDSP.h; these are patch-file IDs,
/// not view ordering or a third-party plug-in parameter namespace.
public enum StudioAnalogParameter: Int32, CaseIterable, Codable, Sendable {
    case oscillator1Wave = 0
    case oscillator2Wave = 1
    case oscillator1Level = 2
    case oscillator2Level = 3
    case noiseLevel = 4
    case oscillator2Semitones = 5
    case filterCutoff = 6
    case resonance = 7
    case filterEnvelopeDepth = 8
    case filterAttack = 9
    case filterDecay = 10
    case filterSustain = 11
    case filterRelease = 12
    case amplitudeAttack = 13
    case amplitudeDecay = 14
    case amplitudeSustain = 15
    case amplitudeRelease = 16
    case lfoRate = 17
    case lfoDepth = 18
    case masterGain = 19
    case pulseWidth = 20

    public var defaultValue: Float {
        switch self {
        case .oscillator1Wave: return 2
        case .oscillator2Wave: return 3
        case .oscillator1Level: return 0.48
        case .oscillator2Level: return 0.28
        case .noiseLevel: return 0
        case .oscillator2Semitones: return 0
        case .filterCutoff: return 6_500
        case .resonance: return 0.18
        case .filterEnvelopeDepth: return 0.4
        case .filterAttack: return 0.01
        case .filterDecay: return 0.25
        case .filterSustain: return 0.5
        case .filterRelease: return 0.3
        case .amplitudeAttack: return 0.005
        case .amplitudeDecay: return 0.18
        case .amplitudeSustain: return 0.75
        case .amplitudeRelease: return 0.25
        case .lfoRate: return 4
        case .lfoDepth: return 0
        case .masterGain: return 0.45
        case .pulseWidth: return 0.5
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .oscillator1Wave, .oscillator2Wave: return 0...3
        case .oscillator2Semitones: return -24...24
        case .filterCutoff: return 20...20_000
        case .lfoRate: return 0.01...40
        case .pulseWidth: return 0.05...0.95
        case .filterAttack, .filterDecay, .filterRelease,
             .amplitudeAttack, .amplitudeDecay, .amplitudeRelease:
            // UI range; C++ engine permits up to 30-second envelopes.
            return 0.001...10
        default: return 0...1
        }
    }

    public var isLogarithmic: Bool {
        switch self {
        case .filterCutoff, .lfoRate,
             .filterAttack, .filterDecay, .filterRelease,
             .amplitudeAttack, .amplitudeDecay, .amplitudeRelease:
            return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .oscillator1Wave, .oscillator2Wave: return "Wave"
        case .oscillator1Level, .oscillator2Level, .noiseLevel: return "Level"
        case .oscillator2Semitones: return "Tune"
        case .filterCutoff: return "Cutoff"
        case .resonance: return "Resonance"
        case .filterEnvelopeDepth: return "Envelope Amount"
        case .filterAttack, .amplitudeAttack: return "Attack"
        case .filterDecay, .amplitudeDecay: return "Decay"
        case .filterSustain, .amplitudeSustain: return "Sustain"
        case .filterRelease, .amplitudeRelease: return "Release"
        case .lfoRate: return "Rate"
        case .lfoDepth: return "Filter Depth"
        case .masterGain: return "Output"
        case .pulseWidth: return "Pulse Width"
        }
    }

    public func valid(_ value: Float) -> Bool {
        guard value.isFinite else { return false }
        if self == .oscillator1Wave || self == .oscillator2Wave {
            return (0...3).contains(value) && value.rounded(.towardZero) == value
        }
        return range.contains(value)
    }

    /// Convert a slider's linear 0...1 travel to the synthesis parameter.
    /// Frequency and envelope time controls use exponential spacing.
    public func value(at position: Double) -> Float {
        let position = min(1, max(0, position.isFinite ? position : 0))
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        if isLogarithmic {
            return Float(lower * pow(upper / lower, position))
        }
        return Float(lower + (upper - lower) * position)
    }

    public func position(for value: Float) -> Double {
        let value = Double(min(range.upperBound, max(range.lowerBound, value)))
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        if isLogarithmic {
            return log(value / lower) / log(upper / lower)
        }
        return (value - lower) / (upper - lower)
    }

    public func displayValue(_ value: Float) -> String {
        switch self {
        case .oscillator1Wave, .oscillator2Wave:
            return StudioAnalogWaveform(rawValue: Int(value))?.title ?? "Unknown"
        case .oscillator2Semitones: return String(format: "%+.1f st", value)
        case .filterCutoff:
            return value >= 1_000 ? String(format: "%.2f kHz", value / 1_000) :
                                    String(format: "%.0f Hz", value)
        case .lfoRate: return String(format: "%.2f Hz", value)
        case .filterAttack, .filterDecay, .filterRelease,
             .amplitudeAttack, .amplitudeDecay, .amplitudeRelease:
            return value < 1 ? String(format: "%.0f ms", value * 1_000) :
                               String(format: "%.2f s", value)
        default: return String(format: "%.0f%%", value * 100)
        }
    }
}

public enum StudioAnalogWaveform: Int, CaseIterable, Identifiable {
    case sine = 0
    case triangle = 1
    case saw = 2
    case pulse = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .saw: return "Saw"
        case .pulse: return "Pulse"
        }
    }
}

/// Patch parameters are independent from a plug-in slot or ARIA preset.
/// Missing and invalid values always fall back to native engine defaults.
/// Future schema versions can add modulation routings without changing
/// existing projects or StudioAnalogParameter numeric identities.
public struct StudioAnalogPatch: Codable, Equatable, Sendable {
    public var version: Int = 2
    public var values: [String: Float] = [:]
    /// Nil preserves the original factory graph in older project files.
    /// An explicit array stores the exact audio and modulation cables.
    public var connections: [StudioAnalogConnection]?

    public init() {}

    public func value(for parameter: StudioAnalogParameter) -> Float {
        guard let stored = values[String(parameter.rawValue)], parameter.valid(stored) else {
            return parameter.defaultValue
        }
        return stored
    }

    public mutating func set(_ value: Float, for parameter: StudioAnalogParameter) {
        guard parameter.valid(value) else { return }
        values[String(parameter.rawValue)] = value
    }

    public var activeConnections: [StudioAnalogConnection] {
        connections ?? StudioAnalogConnection.factory
    }

    public mutating func reset() {
        values.removeAll()
        connections = nil
    }
}
