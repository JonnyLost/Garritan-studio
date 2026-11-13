import Foundation

/// Parameters are stable, append-only IDs shared with StudioGranularDSP.h.
public enum StudioGranularParameter: Int32, Codable, CaseIterable, Sendable {
    case grainSize=0, density=1, position=2, scanSpeed=3, pitch=4
    case pitchJitter=5, positionJitter=6, panSpread=7
    case attack=8, release=9, gain=10, reverse=11, window=12

    public var name: String {
        switch self {
        case .grainSize: return "Grain Size"
        case .density: return "Density"
        case .position: return "Source Position"
        case .scanSpeed: return "Scan Speed"
        case .pitch: return "Pitch Shift"
        case .pitchJitter: return "Pitch Random"
        case .positionJitter: return "Position Random"
        case .panSpread: return "Stereo Spread"
        case .attack: return "Attack"
        case .release: return "Release"
        case .gain: return "Output"
        case .reverse: return "Reverse Chance"
        case .window: return "Grain Window"
        }
    }
    public var range: ClosedRange<Float> {
        switch self {
        case .grainSize: return 0.01...0.5
        case .density: return 1...80
        case .scanSpeed: return -1...1
        case .pitch: return -24...24
        case .pitchJitter: return 0...12
        case .attack,.release: return 0.001...12
        default: return 0...1
        }
    }
    public var defaultValue: Float {
        switch self {
        case .grainSize: return 0.105
        case .density: return 19
        case .position: return 0.45
        case .scanSpeed,.pitch: return 0
        case .pitchJitter: return 0.1
        case .positionJitter: return 0.08
        case .panSpread: return 0.5
        case .attack: return 0.015
        case .release: return 0.32
        case .gain: return 0.55
        case .reverse: return 0
        case .window: return 0.85
        }
    }
    public var logarithmic: Bool {
        switch self {
        case .grainSize,.density,.attack,.release: return true
        default: return false
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
    public func displayValue(_ v: Float) -> String {
        switch self {
        case .grainSize,.attack,.release:
            return v < 1 ? String(format:"%.0f ms",v*1000) :
                           String(format:"%.2f s",v)
        case .density: return String(format:"%.0f / sec",v)
        case .pitch,.pitchJitter: return String(format:"%.1f st",v)
        case .scanSpeed: return String(format:"%+.2f",v)
        case .position,.positionJitter,.panSpread,.gain,.reverse,.window:
            return String(format:"%.0f%%",v*100)
        }
    }
}

public enum StudioGranularSource: Int, Codable, CaseIterable, Identifiable, Sendable {
    case cloud=0, strings=1, bells=2, noise=3
    public var id: Int { rawValue }
    public var name: String {
        switch self {
        case .cloud: return "Harmonic Cloud"
        case .strings: return "Evolving Strings"
        case .bells: return "Bell Fragments"
        case .noise: return "Air / Noise"
        }
    }
}

/// Bounded source: factory wave or a locally imported mono/multichannel file.
/// A file is decoded to a fixed-size PCM buffer BEFORE the audio graph starts;
/// no AVAudioFile, file I/O or disk streaming on the render thread.
public struct StudioGranularPatch: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var values: [String:Float] = [:]
    public var source: StudioGranularSource = .cloud
    public var importedAudioPath: String? = nil

    public init() {}

    public func value(for parameter: StudioGranularParameter) -> Float {
        guard let stored=values[String(parameter.rawValue)],
              parameter.valid(stored) else { return parameter.defaultValue }
        return stored
    }
    public mutating func set(_ value: Float, for parameter: StudioGranularParameter) {
        guard parameter.valid(value) else {return}
        values[String(parameter.rawValue)]=value
    }
    public func validate() -> Bool {
        version==1 && values.allSatisfy { key,value in
            guard let id=Int32(key),
                  let param=StudioGranularParameter(rawValue:id) else { return false }
            return param.valid(value)
        } && (importedAudioPath == nil ||
              (!importedAudioPath!.isEmpty && importedAudioPath!.count <= 2048))
    }
}
