import Foundation

/// Fixed first-generation analog modules. These IDs match the native C ABI.
/// Future synthesis families may use a generalized, instance-based registry;
/// they must not reuse these persisted IDs with different meanings.
public enum StudioAnalogModule: UInt8, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case oscillator1 = 0
    case oscillator2 = 1
    case noise = 2
    case mixer = 3
    case filterEnvelope = 4
    case lfo = 5
    case filter = 6
    case amplitudeEnvelope = 7
    case vca = 8
    case output = 9

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .oscillator1: return "OSCILLATOR 1"
        case .oscillator2: return "OSCILLATOR 2"
        case .noise: return "NOISE"
        case .mixer: return "MIXER"
        case .filterEnvelope: return "FILTER ADSR"
        case .lfo: return "LFO"
        case .filter: return "FILTER"
        case .amplitudeEnvelope: return "AMP ADSR"
        case .vca: return "VCA"
        case .output: return "OUTPUT"
        }
    }

    public var subtitle: String {
        switch self {
        case .oscillator1, .oscillator2: return "Polyphonic oscillator"
        case .noise: return "White noise"
        case .mixer: return "Audio sum"
        case .filterEnvelope: return "Filter contour"
        case .lfo: return "Sine modulation"
        case .filter: return "Resonant low-pass"
        case .amplitudeEnvelope: return "Amplitude contour"
        case .vca: return "Voltage-controlled amp"
        case .output: return "Studio track mixer"
        }
    }

    public var signal: StudioAnalogSignal {
        switch self {
        case .filterEnvelope, .lfo, .amplitudeEnvelope: return .modulation
        default: return .audio
        }
    }

    public var isOutputAvailable: Bool { self != .output }

    /// Destination jacks are explicitly typed and numbered to match the C++
    /// module graph. The first analog board does not expose arbitrary input
    /// creation or dedicated oscillator-pitch modulation ports.
    public var inputs: [StudioAnalogInput] {
        switch self {
        case .mixer:
            return [.init(index: 0, name: "IN 1", signal: .audio),
                    .init(index: 1, name: "IN 2", signal: .audio),
                    .init(index: 2, name: "IN 3", signal: .audio)]
        case .filter:
            return [.init(index: 0, name: "AUDIO", signal: .audio),
                    .init(index: 1, name: "ENV", signal: .modulation),
                    .init(index: 2, name: "LFO", signal: .modulation)]
        case .vca:
            return [.init(index: 0, name: "AUDIO", signal: .audio),
                    .init(index: 1, name: "LEVEL", signal: .modulation)]
        case .output:
            return [.init(index: 0, name: "AUDIO", signal: .audio)]
        default: return []
        }
    }
}

public enum StudioAnalogSignal: String, Codable, Hashable, Sendable {
    case audio
    case modulation
}

public struct StudioAnalogInput: Hashable, Sendable, Identifiable {
    public let index: UInt8
    public let name: String
    public let signal: StudioAnalogSignal

    public init(index: UInt8, name: String, signal: StudioAnalogSignal) {
        self.index = index
        self.name = name
        self.signal = signal
    }

    public var id: UInt8 { index }
}

/// A single typed cable, persisted in the native patch. One input accepts at
/// most one cable; a source output can feed multiple destination inputs.
/// Signed gain supports polarity inversion as well as attenuation.
public struct StudioAnalogConnection: Codable, Hashable, Sendable, Identifiable {
    public let source: StudioAnalogModule
    public let destination: StudioAnalogModule
    public let input: UInt8
    public var gain: Float

    public init(source: StudioAnalogModule, destination: StudioAnalogModule,
                input: UInt8, gain: Float = 1) {
        self.source = source
        self.destination = destination
        self.input = input
        self.gain = gain
    }

    public var id: String { "\(source.rawValue)-\(destination.rawValue)-\(input)" }

    public var signal: StudioAnalogSignal { source.signal }

    public var isLocallyValid: Bool {
        guard source.isOutputAvailable, gain.isFinite, (-4...4).contains(gain),
              let jack = destination.inputs.first(where: { $0.index == input }) else {
            return false
        }
        return source.signal == jack.signal
    }

    public static let factory: [StudioAnalogConnection] = [
        .init(source: .oscillator1, destination: .mixer, input: 0),
        .init(source: .oscillator2, destination: .mixer, input: 1),
        .init(source: .noise, destination: .mixer, input: 2),
        .init(source: .mixer, destination: .filter, input: 0),
        .init(source: .filterEnvelope, destination: .filter, input: 1),
        .init(source: .lfo, destination: .filter, input: 2),
        .init(source: .filter, destination: .vca, input: 0),
        .init(source: .amplitudeEnvelope, destination: .vca, input: 1),
        .init(source: .vca, destination: .output, input: 0)
    ]

    /// UI-side fast rejection; the native graph compiler is authoritative
    /// for cycle detection and full graph validation.
    public static func preliminarilyValid(_ routes: [StudioAnalogConnection]) -> Bool {
        guard !routes.isEmpty, routes.count <= 24,
              routes.allSatisfy(\.isLocallyValid) else { return false }
        let endpoints = Set(routes.map { "\($0.destination.rawValue):\($0.input)" })
        return endpoints.count == routes.count
    }
}
