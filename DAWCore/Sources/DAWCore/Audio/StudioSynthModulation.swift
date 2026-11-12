import Foundation

// MARK: - Native, portable cross-engine modulation matrix

/// Global, control-rate sources shared by all Studio Synth layers.
/// The envelope is a MONOPHONIC gate (last key released); individual voice
/// modulation remains inside each original native synthesis engine.
public enum StudioSynthModSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case lfo1, lfo2, envelope, modWheel, macro1
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lfo1: return "LFO 1 · Sine"
        case .lfo2: return "LFO 2 · Triangle"
        case .envelope: return "Shared ADSR"
        case .modWheel: return "MIDI CC1"
        case .macro1: return "Macro 1"
        }
    }
}

/// Distinct strongly typed targets avoid mixing Analog/FM/Wavetable numeric IDs.
/// Only continuously variable targets are exposed: discrete algorithm/waveform
/// settings must never be modulated to invalid fractional parameter values.
public enum StudioSynthModDestination: Codable, Hashable, Sendable {
    case analog(StudioAnalogParameter)
    case fm(StudioFMParameter)
    case wavetable(StudioWavetableParameter)

    public var engine: StudioSynthEngine {
        switch self {
        case .analog: return .analog
        case .fm: return .fm
        case .wavetable: return .wavetable
        }
    }

    public var title: String {
        switch self {
        case .analog(let parameter):
            return "Analog · \(parameter.displayName)"
        case .fm(let parameter):
            let op = parameter.operatorIndex.map { "Op \($0 + 1) · " } ?? ""
            return "FM · \(op)\(parameter.name)"
        case .wavetable(let parameter):
            return "WT · \(parameter.name)"
        }
    }

    public static func available(for engine: StudioSynthEngine) -> [Self] {
        switch engine {
        case .analog:
            return [.analog(.filterCutoff), .analog(.resonance),
                    .analog(.oscillator1Level), .analog(.oscillator2Level),
                    .analog(.noiseLevel), .analog(.pulseWidth),
                    .analog(.filterEnvelopeDepth), .analog(.masterGain)]
        case .fm:
            return [.fm(.feedback), .fm(.outputGain), .fm(.op1Level),
                    .fm(.op2Level), .fm(.op3Level), .fm(.op4Level),
                    .fm(.op1Ratio), .fm(.op2Ratio), .fm(.modDepth),
                    .fm(.velocityBrightness)]
        case .wavetable:
            return [.wavetable(.osc1Position), .wavetable(.osc2Position),
                    .wavetable(.osc1Level), .wavetable(.osc2Level),
                    .wavetable(.osc2Detune), .wavetable(.outputGain),
                    .wavetable(.lfoDepth)] +
                    (0..<16).compactMap {
                        StudioWavetableParameter.partial($0).map(Self.wavetable)
                    }
        }
    }

    public var isContinuouslyModulatable: Bool {
        Self.available(for: engine).contains(self)
    }

    public var defaultValue: Float {
        switch self {
        case .analog(let p): return p.defaultValue
        case .fm(let p): return p.defaultValue
        case .wavetable(let p): return p.defaultValue
        }
    }

    public func position(for value: Float) -> Double {
        switch self {
        case .analog(let p): return p.position(for: value)
        case .fm(let p): return p.position(for: value)
        case .wavetable(let p): return p.position(for: value)
        }
    }

    public func value(at position: Double) -> Float {
        switch self {
        case .analog(let p): return p.value(at: position)
        case .fm(let p): return p.value(at: position)
        case .wavetable(let p): return p.value(at: position)
        }
    }

    public func valid(_ value: Float) -> Bool {
        switch self {
        case .analog(let p): return p.valid(value)
        case .fm(let p): return p.valid(value)
        case .wavetable(let p): return p.valid(value)
        }
    }

    /// Combine bipolar source contributions in normalized parameter space.
    /// Logarithmic frequency/ratio controls therefore sweep perceptually,
    /// while every result remains strictly inside its native DSP range.
    public func apply(base: Float, normalizedOffset: Float) -> Float {
        let position = position(for: base)
        let offset = normalizedOffset.isFinite ? Double(normalizedOffset) : 0
        return value(at: min(1, max(0, position + offset)))
    }
}

public struct StudioSynthModRoute: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var source: StudioSynthModSource
    public var layerID: UUID
    public var destination: StudioSynthModDestination
    /// Signed normalized sweep depth, -1 ... +1.
    public var depth: Float

    public init(id: UUID = UUID(), enabled: Bool = true,
                source: StudioSynthModSource, layerID: UUID,
                destination: StudioSynthModDestination,
                depth: Float = 0.25) {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.layerID = layerID
        self.destination = destination
        self.depth = depth
    }
}

/// Musical duration for one LFO cycle, measured in quarter-note beats.
/// Raw strings are stable values in saved project files and factory patches.
public enum StudioSynthLFONote: String, Codable, CaseIterable, Identifiable, Sendable {
    case whole, half, quarter, eighth, sixteenth, thirtySecond, sixtyFourth

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .whole: return "1/1"
        case .half: return "1/2"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .thirtySecond: return "1/32"
        case .sixtyFourth: return "1/64"
        }
    }
    public var beats: Double {
        switch self {
        case .whole: return 4
        case .half: return 2
        case .quarter: return 1
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        case .thirtySecond: return 0.125
        case .sixtyFourth: return 0.0625
        }
    }
}

public enum StudioSynthLFOTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    case straight, dotted, triplet
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .straight: return "Straight"
        case .dotted: return "Dotted"
        case .triplet: return "Triplet"
        }
    }
    public var multiplier: Double {
        switch self {
        case .straight: return 1
        case .dotted: return 1.5
        case .triplet: return 2.0 / 3.0
        }
    }
}

/// A nil sync setting means free-running Hz, preserving every pre-sync patch.
public struct StudioSynthLFOSync: Codable, Equatable, Sendable {
    public var note: StudioSynthLFONote
    public var timing: StudioSynthLFOTiming

    public init(note: StudioSynthLFONote = .quarter,
                timing: StudioSynthLFOTiming = .straight) {
        self.note = note
        self.timing = timing
    }

    public var beatsPerCycle: Double { note.beats * timing.multiplier }
}

/// Settings belong to the *Studio Synth* patch, never a single engine. Old
/// project files decode with modulation=nil and remain exactly unmodulated.
public struct StudioSynthModulationSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var lfo1Rate: Float
    public var lfo2Rate: Float
    /// Nil = free-running Hz. Optional keys decode as nil from old project JSON.
    public var lfo1Sync: StudioSynthLFOSync?
    public var lfo2Sync: StudioSynthLFOSync?
    /// Optional 0...1 cycle offsets, absent from old patches (phase zero).
    public var lfo1Phase: Float?
    public var lfo2Phase: Float?
    public var envelopeAttack: Float
    public var envelopeDecay: Float
    public var envelopeSustain: Float
    public var envelopeRelease: Float
    public var macro1: Float
    public var routes: [StudioSynthModRoute]

    public init(version: Int = 1, lfo1Rate: Float = 0.45, lfo2Rate: Float = 0.18,
                lfo1Sync: StudioSynthLFOSync? = nil,
                lfo2Sync: StudioSynthLFOSync? = nil,
                lfo1Phase: Float? = nil, lfo2Phase: Float? = nil,
                envelopeAttack: Float = 0.08, envelopeDecay: Float = 0.3,
                envelopeSustain: Float = 0.7, envelopeRelease: Float = 0.5,
                macro1: Float = 0, routes: [StudioSynthModRoute] = []) {
        self.version = version
        self.lfo1Rate = lfo1Rate
        self.lfo2Rate = lfo2Rate
        self.lfo1Sync = lfo1Sync
        self.lfo2Sync = lfo2Sync
        self.lfo1Phase = lfo1Phase
        self.lfo2Phase = lfo2Phase
        self.envelopeAttack = envelopeAttack
        self.envelopeDecay = envelopeDecay
        self.envelopeSustain = envelopeSustain
        self.envelopeRelease = envelopeRelease
        self.macro1 = macro1
        self.routes = routes
    }

    public func validate(layers: [StudioSynthLayer]) -> Bool {
        guard version == 1, routes.count <= 24,
              Set(routes.map(\.id)).count == routes.count,
              lfo1Rate.isFinite, (0.03...15).contains(lfo1Rate),
              lfo2Rate.isFinite, (0.03...15).contains(lfo2Rate),
              (lfo1Phase.map { $0.isFinite && (0...1).contains($0) } ?? true),
              (lfo2Phase.map { $0.isFinite && (0...1).contains($0) } ?? true),
              envelopeAttack.isFinite, (0.01...20).contains(envelopeAttack),
              envelopeDecay.isFinite, (0.01...20).contains(envelopeDecay),
              envelopeSustain.isFinite, (0...1).contains(envelopeSustain),
              envelopeRelease.isFinite, (0.01...20).contains(envelopeRelease),
              macro1.isFinite, (0...1).contains(macro1) else { return false }
        return routes.allSatisfy { route in
            guard route.depth.isFinite, (-1...1).contains(route.depth),
                  route.destination.isContinuouslyModulatable,
                  let layer = layers.first(where: { $0.id == route.layerID }) else {
                return false
            }
            return layer.engine == route.destination.engine
        }
    }

    public var hasEnabledRoutes: Bool { routes.contains(where: \.enabled) }
}

/// A small deterministic evaluator, shared by runtime and regression tests.
/// LFOs are bipolar -1...+1; envelope, CC1 and macro are unipolar 0...1.
public enum StudioSynthModulationMath {
    /// Keep the usual inexpensive 50Hz worker for ordinary modulations.
    /// Only high-frequency synced LFOs actually routed to a destination
    /// request more samples/cycle (up to a conservative 400Hz maximum).
    /// No additional thread or DSP render work is created.
    public static func controlRate(
        _ settings: StudioSynthModulationSettings, bpm: Double
    ) -> Double {
        guard bpm.isFinite && bpm > 0 else { return 50 }
        var rate = 50.0
        for route in settings.routes where route.enabled {
            let sync: StudioSynthLFOSync?
            switch route.source {
            case .lfo1: sync = settings.lfo1Sync
            case .lfo2: sync = settings.lfo2Sync
            default: sync = nil
            }
            if let sync {
                let cyclesPerSecond = (bpm / 60) / sync.beatsPerCycle
                rate = max(rate, min(400, cyclesPerSecond * 8))
            }
        }
        return rate
    }

    public static func signal(
        _ source: StudioSynthModSource, seconds: Double,
        settings: StudioSynthModulationSettings,
        envelope: Float, wheel: Float,
        bpm: Double = 120, beats: Double? = nil
    ) -> Float {
        // The worker integrates beat position continuously as BPM changes.
        // Passing beats prevents LFO phase jumps on live tempo edits; the
        // default also makes this pure evaluator easy to test in isolation.
        let beatPosition = beats ?? seconds * (bpm / 60)
        switch source {
        case .lfo1:
            let cycle = (settings.lfo1Sync.map { beatPosition / $0.beatsPerCycle }
                ?? (seconds * Double(settings.lfo1Rate))) +
                Double(settings.lfo1Phase ?? 0)
            return Float(sin(2 * Double.pi * cycle))
        case .lfo2:
            let cycle = (settings.lfo2Sync.map { beatPosition / $0.beatsPerCycle }
                ?? (seconds * Double(settings.lfo2Rate))) +
                Double(settings.lfo2Phase ?? 0)
            let fraction = cycle - floor(cycle)
            return Float(1 - 4 * abs(fraction - 0.5))
        case .envelope: return min(1, max(0, envelope))
        case .modWheel: return min(1, max(0, wheel))
        case .macro1: return settings.macro1
        }
    }
}

/// Global gate envelope for a cross-layer control source. Stepped only on the
/// non-realtime modulation worker; does not replace per-voice synth ADSRs.
public struct StudioSynthModulationEnvelope {
    private enum Phase { case idle, attack, decay, sustain, release }
    private var phase: Phase = .idle
    private var releaseStart: Float = 0
    public private(set) var value: Float = 0

    public init() {}
    public mutating func trigger() {
        value = 0
        phase = .attack
    }
    public mutating func release() {
        guard phase != .idle && phase != .release else { return }
        releaseStart = value
        phase = .release
    }
    public mutating func reset() {
        phase = .idle
        value = 0
        releaseStart = 0
    }
    public mutating func advance(
        seconds: Double, settings: StudioSynthModulationSettings
    ) -> Float {
        let dt = Float(min(0.2, max(0, seconds.isFinite ? seconds : 0)))
        switch phase {
        case .idle: value = 0
        case .attack:
            value = min(1, value + dt / settings.envelopeAttack)
            if value >= 1 { phase = .decay }
        case .decay:
            value = max(settings.envelopeSustain,
                        value - dt * (1 - settings.envelopeSustain) /
                        settings.envelopeDecay)
            if value <= settings.envelopeSustain { phase = .sustain }
        case .sustain: value = settings.envelopeSustain
        case .release:
            value = max(0, value - dt * releaseStart / settings.envelopeRelease)
            if value <= 0 { phase = .idle }
        }
        return value
    }
}
