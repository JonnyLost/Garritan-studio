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
    /// Six octave-band RT targets only for designed rooms. Existing presets
    /// retain their original three-band DSP mode.
    public var sixBandRT60: [Float]?
    /// Optional designer-only change to FDN delay spacing. Nil = factory timing.
    public var lateDelayScale: Float?
    /// Optional designer-only diffuse wall absorption coloration in early taps.
    /// Nil = original unfiltered factory reflections.
    public var earlyReflectionHighCutHz: Float?
    public var earlyReflections: [StudioEarlyReflection]

    public init(id: String, name: String, bassRT60: Float, midRT60: Float,
                trebleRT60: Float, earlyReflections: [StudioEarlyReflection],
                sixBandRT60: [Float]? = nil,
                lateDelayScale: Float? = nil,
                earlyReflectionHighCutHz: Float? = nil) {
        self.id = id
        self.name = name
        self.bassRT60 = bassRT60
        self.midRT60 = midRT60
        self.trebleRT60 = trebleRT60
        self.sixBandRT60 = sixBandRT60
        self.lateDelayScale = lateDelayScale
        self.earlyReflectionHighCutHz = earlyReflectionHighCutHz
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

    /// Inspired by the historically measured 1.0–1.3s mid-frequency decay
    /// of the MGM/Sony scoring stage. Reflection timings are artistic estimates.
    /// Not a measured replica or an endorsed Sony Pictures product.
    public static let mgmSonyScoringInspired = StudioRoomAcousticProfile(
        id: "mgm-sony-scoring-inspired", name: "MGM / Sony Scoring · Inspired",
        bassRT60: 1.35, midRT60: 1.15, trebleRT60: 1.05,
        earlyReflections: [
            .init(delayMilliseconds: 11, leftGain: 0.28, rightGain: 0.16),
            .init(delayMilliseconds: 17, leftGain: 0.14, rightGain: 0.27),
            .init(delayMilliseconds: 24, leftGain: -0.10, rightGain: 0.12),
            .init(delayMilliseconds: 32, leftGain: 0.13, rightGain: -0.10),
            .init(delayMilliseconds: 43, leftGain: 0.08, rightGain: 0.09)
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

    /// Order is stable: this index is the Audio Unit's room parameter value.
    /// Persist profile IDs, never numeric indices, in Studio project files.
    public static let starterProfiles: [StudioRoomAcousticProfile] = [
        .abbeyRoadStudioOne, .mgmSonyScoringInspired,
        .synchronViennaInspired, .bostonSymphonyInspired
    ]

    /// The custom slot always follows the four historic factory profiles.
    /// All AU parameter indices refer to this stable order.
    public static let customProfileIndex = starterProfiles.count
    public static let playableProfileCount = starterProfiles.count + 1

    public static var playableProfiles: [StudioRoomAcousticProfile] {
        starterProfiles + [StudioAcousticRoomDesign().makeProfile()]
    }

    public static func profiles(with design: StudioAcousticRoomDesign)
        -> [StudioRoomAcousticProfile] {
        starterProfiles + [design.makeProfile()]
    }

    public static func index(forID id: String) -> Int? {
        if id == StudioAcousticRoomDesign.profileID { return customProfileIndex }
        return starterProfiles.firstIndex(where: { $0.id == id })
    }
}
