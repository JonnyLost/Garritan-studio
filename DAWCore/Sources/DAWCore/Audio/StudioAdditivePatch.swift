import Foundation

/// Parameter numbers match StudioAdditiveDSP.h. The 16 separate partial
/// amplitudes are not stored as sample data; every sound is deterministic.
public enum StudioAdditiveParameter: Int32, Codable, CaseIterable, Sendable {
    case attack=0, decay=1, sustain=2, release=3, outputGain=4
    case spectralTilt=5, spectralEvolution=6, evolutionTime=7, bendRange=8
    case partial1=9, partial2=10, partial3=11, partial4=12
    case partial5=13, partial6=14, partial7=15, partial8=16
    case partial9=17, partial10=18, partial11=19, partial12=20
    case partial13=21, partial14=22, partial15=23, partial16=24

    public static func partial(_ index: Int) -> Self? {
        guard (0..<16).contains(index) else { return nil }
        return Self(rawValue: Int32(index+9))
    }
    public var harmonicIndex: Int? {
        rawValue>=9 ? Int(rawValue-9) : nil
    }
    public var name: String {
        switch self {
        case .attack: return "Attack"
        case .decay: return "Decay"
        case .sustain: return "Sustain"
        case .release: return "Release"
        case .outputGain: return "Output"
        case .spectralTilt: return "Spectral Tilt"
        case .spectralEvolution: return "Spectral Evolution"
        case .evolutionTime: return "Evolution Time"
        case .bendRange: return "Bend Range"
        default: return "Harmonic \((harmonicIndex ?? 0)+1)"
        }
    }
    public var defaultValue: Float {
        switch self {
        case .attack: return 0.008
        case .decay: return 0.28
        case .sustain: return 0.72
        case .release: return 0.3
        case .outputGain: return 0.65
        case .spectralTilt: return 0
        case .spectralEvolution: return 0.45
        case .evolutionTime: return 1.8
        case .bendRange: return 2
        default:
            let levels: [Float] = [0.8,0.28,0.15,0.12,0.07,0.05,0.04,0.025,
                                   0.018,0.012,0.01,0.008,0.006,0.004,0.003,0.002]
            return levels[harmonicIndex!]
        }
    }
    public var range: ClosedRange<Float> {
        switch self {
        case .attack,.decay,.release: return 0.001...30
        case .evolutionTime: return 0.05...20
        case .spectralTilt,.spectralEvolution: return -2...2
        case .bendRange: return 0...24
        default: return 0...1
        }
    }
    public var logarithmic: Bool {
        switch self {
        case .attack,.decay,.release,.evolutionTime: return true
        default: return false
        }
    }
    public func valid(_ value: Float) -> Bool { value.isFinite && range.contains(value) }
    public func position(for value: Float) -> Double {
        let v=Double(min(range.upperBound,max(range.lowerBound,value)))
        let lo=Double(range.lowerBound),hi=Double(range.upperBound)
        return logarithmic ? log(v/lo)/log(hi/lo) : (v-lo)/(hi-lo)
    }
    public func value(at position: Double) -> Float {
        let t=min(1,max(0,position.isFinite ? position:0))
        let lo=Double(range.lowerBound),hi=Double(range.upperBound)
        return Float(logarithmic ? lo*pow(hi/lo,t) : lo+(hi-lo)*t)
    }
    public func displayValue(_ value: Float) -> String {
        switch self {
        case .attack,.decay,.release,.evolutionTime:
            return value<1 ? String(format:"%.0f ms",value*1000) :
                             String(format:"%.2f s",value)
        case .bendRange: return String(format:"%.1f st",value)
        case .spectralTilt,.spectralEvolution:
            return String(format:"%+.2f",value)
        default: return String(format:"%.2f",value)
        }
    }
}

public struct StudioAdditivePatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var values: [String:Float] = [:]
    public init() {}
    public func value(for parameter: StudioAdditiveParameter) -> Float {
        guard let value=values[String(parameter.rawValue)],
              parameter.valid(value) else {return parameter.defaultValue}
        return value
    }
    public mutating func set(_ value: Float,for parameter: StudioAdditiveParameter) {
        guard parameter.valid(value) else {return}
        values[String(parameter.rawValue)]=value
    }
    public func validate() -> Bool {
        version==1 && values.allSatisfy { key,value in
            guard let id=Int32(key), let param=StudioAdditiveParameter(rawValue:id)
                else {return false}
            return param.valid(value)
        }
    }
}
