import Foundation

/// Perceptually tuned early reflection. Times are design estimates, not measured
/// impulse-response taps from the rooms that inspired these profiles.
public struct StudioEarlyReflection: Codable, Equatable, Sendable {
    public var delayMilliseconds: Float
    public var leftGain: Float
    public var rightGain: Float

    public init(delayMilliseconds: Float, leftGain: Float, rightGain: Float) {
        self.delayMilliseconds = delayMilliseconds
        self.leftGain = leftGain
        self.rightGain = rightGain
    }
}

/// Editable, portable room characteristics for Studio's original algorithmic DSP.
/// No recorded room responses, third-party plugins, or convolution are involved.
public struct StudioRoomAcousticProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bassRT60: Float
    public var midRT60: Float
    public var trebleRT60: Float
    public var earlyReflections: [StudioEarlyReflection]

    public init(id: String, name: String, bassRT60: Float, midRT60: Float,
                trebleRT60: Float, earlyReflections: [StudioEarlyReflection]) {
        self.id = id
        self.name = name
        self.bassRT60 = bassRT60
        self.midRT60 = midRT60
        self.trebleRT60 = trebleRT60
        self.earlyReflections = earlyReflections
    }

    /// Inspired by Studio One's approximately 2.2s mid-frequency decay.
    /// Band targets and reflection taps are preliminary artistic estimates,
    /// not calibrated measurements or an endorsement by Abbey Road Studios.
    public static let abbeyRoadStudioOne = StudioRoomAcousticProfile(
        id: "abbey-road-one-inspired", name: "Abbey Road One · Inspired",
        bassRT60: 2.4, midRT60: 2.2, trebleRT60: 2.1,
        earlyReflections: [
            .init(delayMilliseconds: 20, leftGain: 0.25, rightGain: 0.14),
            .init(delayMilliseconds: 26, leftGain: 0.11, rightGain: 0.23),
            .init(delayMilliseconds: 32, leftGain: -0.13, rightGain: 0.12),
            .init(delayMilliseconds: 39, leftGain: 0.16, rightGain: -0.11),
            .init(delayMilliseconds: 48, leftGain: 0.09, rightGain: 0.16),
            .init(delayMilliseconds: 61, leftGain: -0.10, rightGain: 0.09),
            .init(delayMilliseconds: 78, leftGain: 0.07, rightGain: -0.08)
        ]
    )

    /// Early settings only; no claim of an acoustically exact venue model.
    public static let synchronViennaInspired = StudioRoomAcousticProfile(
        id: "synchron-vienna-inspired", name: "Vienna Scoring Stage · Inspired",
        bassRT60: 1.8, midRT60: 1.7, trebleRT60: 1.55,
        earlyReflections: [
            .init(delayMilliseconds: 18, leftGain: 0.23, rightGain: 0.15),
            .init(delayMilliseconds: 24, leftGain: 0.13, rightGain: 0.23),
            .init(delayMilliseconds: 30, leftGain: -0.10, rightGain: 0.11),
            .init(delayMilliseconds: 41, leftGain: 0.13, rightGain: -0.09),
            .init(delayMilliseconds: 57, leftGain: 0.09, rightGain: 0.10)
        ]
    )

    public static let bostonSymphonyInspired = StudioRoomAcousticProfile(
        id: "boston-symphony-inspired", name: "Boston Symphony · Inspired",
        bassRT60: 2.2, midRT60: 1.9, trebleRT60: 1.7,
        earlyReflections: [
            .init(delayMilliseconds: 15, leftGain: 0.29, rightGain: 0.18),
            .init(delayMilliseconds: 21, leftGain: 0.15, rightGain: 0.27),
            .init(delayMilliseconds: 29, leftGain: -0.13, rightGain: 0.13),
            .init(delayMilliseconds: 38, leftGain: 0.16, rightGain: -0.11),
            .init(delayMilliseconds: 53, leftGain: 0.11, rightGain: 0.13),
            .init(delayMilliseconds: 76, leftGain: -0.07, rightGain: 0.08)
        ]
    )

    public static let starterProfiles: [StudioRoomAcousticProfile] = [
        .abbeyRoadStudioOne, .synchronViennaInspired, .bostonSymphonyInspired
    ]
}
