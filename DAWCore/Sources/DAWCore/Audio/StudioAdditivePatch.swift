import Foundation

/// Shaping controls are independent for every partial in every voice.
public enum StudioAdditiveHarmonicControl: String, Codable, CaseIterable, Sendable {
    case attack, decay, sustain, release, motion
    public var name: String {
        switch self {
        case .attack: return "Attack"
        case .decay: return "Decay"
        case .sustain: return "Sustain"
        case .release: return "Release"
        case .motion: return "Motion Amount"
        }
    }
}

/// IDs are append-only and match StudioAdditiveDSP.h. Existing patches
/// using IDs 0...24 remain compatible and sound unchanged by default.
public enum StudioAdditiveParameter: Int32, Codable, CaseIterable, Sendable {
    case attack=0, decay=1, sustain=2, release=3, outputGain=4
    case spectralTilt=5, spectralEvolution=6, evolutionTime=7, bendRange=8
    case partial1=9, partial2=10, partial3=11, partial4=12
    case partial5=13, partial6=14, partial7=15, partial8=16
    case partial9=17, partial10=18, partial11=19, partial12=20
    case partial13=21, partial14=22, partial15=23, partial16=24
    case motionRate=25, motionDepth=26, motionSpread=27, motionShape=28
    case partialEnvelopeMix=29
    case harmonicAttack1=30, harmonicAttack2=31, harmonicAttack3=32, harmonicAttack4=33, harmonicAttack5=34, harmonicAttack6=35, harmonicAttack7=36, harmonicAttack8=37, harmonicAttack9=38, harmonicAttack10=39, harmonicAttack11=40, harmonicAttack12=41, harmonicAttack13=42, harmonicAttack14=43, harmonicAttack15=44, harmonicAttack16=45
    case harmonicDecay1=46, harmonicDecay2=47, harmonicDecay3=48, harmonicDecay4=49, harmonicDecay5=50, harmonicDecay6=51, harmonicDecay7=52, harmonicDecay8=53, harmonicDecay9=54, harmonicDecay10=55, harmonicDecay11=56, harmonicDecay12=57, harmonicDecay13=58, harmonicDecay14=59, harmonicDecay15=60, harmonicDecay16=61
    case harmonicSustain1=62, harmonicSustain2=63, harmonicSustain3=64, harmonicSustain4=65, harmonicSustain5=66, harmonicSustain6=67, harmonicSustain7=68, harmonicSustain8=69, harmonicSustain9=70, harmonicSustain10=71, harmonicSustain11=72, harmonicSustain12=73, harmonicSustain13=74, harmonicSustain14=75, harmonicSustain15=76, harmonicSustain16=77
    case harmonicRelease1=78, harmonicRelease2=79, harmonicRelease3=80, harmonicRelease4=81, harmonicRelease5=82, harmonicRelease6=83, harmonicRelease7=84, harmonicRelease8=85, harmonicRelease9=86, harmonicRelease10=87, harmonicRelease11=88, harmonicRelease12=89, harmonicRelease13=90, harmonicRelease14=91, harmonicRelease15=92, harmonicRelease16=93
    case harmonicMotion1=94, harmonicMotion2=95, harmonicMotion3=96, harmonicMotion4=97, harmonicMotion5=98, harmonicMotion6=99, harmonicMotion7=100, harmonicMotion8=101, harmonicMotion9=102, harmonicMotion10=103, harmonicMotion11=104, harmonicMotion12=105, harmonicMotion13=106, harmonicMotion14=107, harmonicMotion15=108, harmonicMotion16=109

    public static func partial(_ index: Int) -> Self? {
        guard (0..<16).contains(index) else { return nil }
        return Self(rawValue: Int32(9+index))
    }

    public var harmonicIndex: Int? {
        (9..<25).contains(rawValue) ? Int(rawValue-9) : nil
    }

    public static func harmonic(_ index: Int,
                                control: StudioAdditiveHarmonicControl) -> Self? {
        guard (0..<16).contains(index) else { return nil }
        let base: Int32
        switch control {
        case .attack: base=30
        case .decay: base=46
        case .sustain: base=62
        case .release: base=78
        case .motion: base=94
        }
        return Self(rawValue: base+Int32(index))
    }

    public var harmonicShape: (index: Int, control: StudioAdditiveHarmonicControl)? {
        for control in StudioAdditiveHarmonicControl.allCases {
            guard let first=Self.harmonic(0,control:control) else { continue }
            if rawValue>=first.rawValue && rawValue<first.rawValue+16 {
                return (Int(rawValue-first.rawValue),control)
            }
        }
        return nil
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
        case .motionRate: return "Motion Rate"
        case .motionDepth: return "Motion Depth"
        case .motionSpread: return "Motion Spread"
        case .motionShape: return "Motion Shape"
        case .partialEnvelopeMix: return "Harmonic Envelope Mix"
        default:
            if let index=harmonicIndex { return "Harmonic \(index+1)" }
            if let shape=harmonicShape {
                return "H\(shape.index+1) \(shape.control.name)"
            }
            return "Unknown Harmonic"
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
        case .motionRate: return 0.38
        case .motionDepth: return 0
        case .motionSpread: return 0.35
        case .motionShape, .partialEnvelopeMix: return 0
        default:
            if let shape=harmonicShape {
                switch shape.control {
                case .attack: return 0.001
                case .decay: return 0.2
                case .sustain: return 1
                case .release: return 0.3
                case .motion: return 1
                }
            }
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
        case .motionRate: return 0.02...12
        default:
            if let control=harmonicShape?.control,
               control == .attack || control == .decay || control == .release {
                return 0.001...30
            }
            return 0...1
        }
    }

    public var logarithmic: Bool {
        switch self {
        case .attack,.decay,.release,.evolutionTime,.motionRate: return true
        default:
            guard let control=harmonicShape?.control else { return false }
            return control == .attack || control == .decay || control == .release
        }
    }

    public func valid(_ value: Float) -> Bool {
        value.isFinite && range.contains(value)
    }

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
        case .motionRate: return String(format:"%.2f Hz",value)
        case .motionDepth,.motionSpread,.motionShape,.partialEnvelopeMix:
            return String(format:"%.0f%%",value*100)
        case .bendRange: return String(format:"%.1f st",value)
        case .spectralTilt,.spectralEvolution:
            return String(format:"%+.2f",value)
        default:
            if let control=harmonicShape?.control,
               control == .attack || control == .decay || control == .release {
                return value<1 ? String(format:"%.0f ms",value*1000) :
                                 String(format:"%.2f s",value)
            }
            return String(format:"%.2f",value)
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
