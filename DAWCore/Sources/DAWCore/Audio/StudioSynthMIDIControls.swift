import Foundation

/// Native MIDI CC performance assignment. Targets are strongly typed, so a
/// controller can never accidentally edit a parameter in the wrong DSP engine.
public enum StudioSynthMIDIControlTarget: Codable, Hashable, Sendable {
    case parameter(layerID: UUID, destination: StudioSynthModDestination)
    case macro1

    public var layerID: UUID? {
        if case .parameter(let id, _) = self { return id }
        return nil
    }

    public func validate(layers: [StudioSynthLayer]) -> Bool {
        switch self {
        case .macro1:
            return true
        case .parameter(let id, let destination):
            return destination.isContinuouslyModulatable &&
                layers.contains { $0.id == id && $0.engine == destination.engine }
        }
    }
}

public struct StudioSynthMIDIControlMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    /// MIDI CC number. Bank select, sustain and channel-mode commands are not
    /// assigned by MIDI Learn, so they retain their conventional behavior.
    public var controller: UInt8
    /// Nil accepts every MIDI channel; otherwise use a zero-based channel 0...15.
    public var channel: UInt8?
    public var target: StudioSynthMIDIControlTarget
    /// The destination span in normalized parameter space (0...1). A minimum
    /// above the maximum reverses the controller. Neither value is a DSP unit.
    public var minimum: Float
    public var maximum: Float

    public init(id: UUID = UUID(), enabled: Bool = true, controller: UInt8,
                channel: UInt8? = nil, target: StudioSynthMIDIControlTarget,
                minimum: Float = 0, maximum: Float = 1) {
        self.id = id
        self.enabled = enabled
        self.controller = controller
        self.channel = channel
        self.target = target
        self.minimum = minimum
        self.maximum = maximum
    }

    public static func supportsController(_ number: UInt8) -> Bool {
        (1...119).contains(number) && number != 32 && number != 64
    }

    public func validate(layers: [StudioSynthLayer]) -> Bool {
        Self.supportsController(controller) &&
            (channel.map { $0 < 16 } ?? true) &&
            minimum.isFinite && (0...1).contains(minimum) &&
            maximum.isFinite && (0...1).contains(maximum) &&
            target.validate(layers: layers)
    }

    /// Pure evaluator, also used by deterministic regression tests.
    public func position(for value: UInt8) -> Float? {
        guard value <= 127 else { return nil }
        return minimum + (maximum - minimum) * Float(value) / 127
    }

    public func matches(controller number: UInt8, channel incoming: UInt8) -> Bool {
        enabled && controller == number &&
            (channel == nil || channel == incoming)
    }
}

/// Saved with StudioSynthPatch, independent of hardware endpoint identity.
/// Multiple targets may share a CC; each individual destination has one
/// assignment so controller ownership and removal stay unambiguous.
public struct StudioSynthMIDIControlSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var mappings: [StudioSynthMIDIControlMapping]

    public init(version: Int = 1, mappings: [StudioSynthMIDIControlMapping] = []) {
        self.version = version
        self.mappings = mappings
    }

    public func validate(layers: [StudioSynthLayer]) -> Bool {
        version == 1 && mappings.count <= 32 &&
            Set(mappings.map(\.id)).count == mappings.count &&
            Set(mappings.map(\.target)).count == mappings.count &&
            mappings.allSatisfy { $0.validate(layers: layers) }
    }

    public var hasEnabledMappings: Bool { mappings.contains(where: \.enabled) }
}
