import Foundation

/// Representative random-incidence absorption coefficients at 125, 250,
/// 500, 1000, 2000 and 4000 Hz. Values depend on construction and mounting.
/// These are broad engineering references, not certified product measurements.
///
/// Source examples: US OSHA Technical Manual, Section III, Chapter 5,
/// table V-2 (https://www.osha.gov/otm/section-3-health-hazards/chapter-5).
public enum StudioAcousticSurface: String, Codable, CaseIterable, Identifiable, Sendable {
    case wood
    case paintedPlaster
    case smoothConcrete
    case brick
    case heavyCarpet
    case glass
    case acousticPanel
    case heavyCurtain

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wood: return "Wood"
        case .paintedPlaster: return "Painted plaster"
        case .smoothConcrete: return "Smooth concrete"
        case .brick: return "Bare brick"
        case .heavyCarpet: return "Heavy carpet"
        case .glass: return "Glass"
        case .acousticPanel: return "Fiberglass panel"
        case .heavyCurtain: return "Heavy curtain"
        }
    }

    public var octaveAbsorption: [Double] {
        switch self {
        case .wood: return [0.15, 0.11, 0.10, 0.07, 0.06, 0.07]
        case .paintedPlaster: return [0.013, 0.015, 0.02, 0.03, 0.04, 0.05]
        case .smoothConcrete: return [0.01, 0.01, 0.02, 0.02, 0.02, 0.02]
        case .brick: return [0.03, 0.03, 0.03, 0.04, 0.05, 0.07]
        case .heavyCarpet: return [0.02, 0.06, 0.14, 0.37, 0.60, 0.65]
        case .glass: return [0.18, 0.06, 0.04, 0.03, 0.02, 0.02]
        case .acousticPanel: return [0.12, 0.28, 0.73, 0.89, 0.92, 0.93]
        case .heavyCurtain: return [0.05, 0.12, 0.25, 0.35, 0.40, 0.45]
        }
    }
}

public enum StudioRoomDecayEstimation: String, Codable, CaseIterable, Sendable {
    case sabine
    case eyring

    public var displayName: String {
        switch self {
        case .sabine: return "Sabine"
        case .eyring: return "Eyring"
        }
    }
}

/// Project-persisted designer inputs. All measurements are in meters, regardless
/// of the user's UI unit preferences. Neither formula predicts discrete echoes,
/// flutter, standing waves, or source/microphone perspective.
public struct StudioAcousticRoomDesign: Codable, Equatable, Sendable {
    public var name: String
    public var lengthMeters: Double
    public var widthMeters: Double
    public var heightMeters: Double
    public var wallMaterial: StudioAcousticSurface
    public var floorMaterial: StudioAcousticSurface
    public var ceilingMaterial: StudioAcousticSurface
    /// Fraction of the wall surface replaced by additional treatment (0...1).
    public var treatedWallFraction: Double
    public var wallTreatmentMaterial: StudioAcousticSurface
    public var method: StudioRoomDecayEstimation

    public init(name: String = "My Acoustic Room",
                lengthMeters: Double = 18, widthMeters: Double = 12,
                heightMeters: Double = 8,
                wallMaterial: StudioAcousticSurface = .wood,
                floorMaterial: StudioAcousticSurface = .wood,
                ceilingMaterial: StudioAcousticSurface = .paintedPlaster,
                treatedWallFraction: Double = 0,
                wallTreatmentMaterial: StudioAcousticSurface = .acousticPanel,
                method: StudioRoomDecayEstimation = .eyring) {
        self.name = name
        self.lengthMeters = lengthMeters
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.wallMaterial = wallMaterial
        self.floorMaterial = floorMaterial
        self.ceilingMaterial = ceilingMaterial
        self.treatedWallFraction = treatedWallFraction
        self.wallTreatmentMaterial = wallTreatmentMaterial
        self.method = method
    }

    public static let bandCentersHz: [Int] = [125, 250, 500, 1_000, 2_000, 4_000]
    public static let profileID = "studio-custom-acoustic-room"

    private static func bounded(_ value: Double, low: Double, high: Double,
                                fallback: Double) -> Double {
        value.isFinite ? max(low, min(high, value)) : fallback
    }

    public var safeLength: Double { Self.bounded(lengthMeters, low: 3, high: 80, fallback: 18) }
    public var safeWidth: Double { Self.bounded(widthMeters, low: 3, high: 80, fallback: 12) }
    public var safeHeight: Double { Self.bounded(heightMeters, low: 2.2, high: 35, fallback: 8) }

    public var volumeCubicMeters: Double { safeLength * safeWidth * safeHeight }
    public var floorArea: Double { safeLength * safeWidth }
    public var wallArea: Double { 2 * safeHeight * (safeLength + safeWidth) }
    public var totalArea: Double { 2 * floorArea + wallArea }

    /// Idealized diffuse-field estimate; not a measured room or ISO-certified
    /// acoustical prediction. Value is intentionally *not* DSP-clamped.
    public var predictedRT60: [Double] {
        let treated = Self.bounded(treatedWallFraction, low: 0, high: 1, fallback: 0)
        let baseWalls = wallMaterial.octaveAbsorption
        let treatment = wallTreatmentMaterial.octaveAbsorption
        let floor = floorMaterial.octaveAbsorption
        let ceiling = ceilingMaterial.octaveAbsorption

        return (0..<6).map { band in
            let wallAlpha = (1 - treated) * baseWalls[band] + treated * treatment[band]
            let equivalentAbsorption =
                floorArea * (floor[band] + ceiling[band]) +
                wallArea * wallAlpha
            let damping: Double
            switch method {
            case .sabine:
                damping = equivalentAbsorption
            case .eyring:
                let meanAlpha = min(0.999, max(0.00001, equivalentAbsorption / totalArea))
                damping = -totalArea * log(1 - meanAlpha)
            }
            return 0.161 * volumeCubicMeters / max(0.00001, damping)
        }
    }

    /// Physically informed, but still artistic: a few image-source-style
    /// reflections from room dimensions and average wall absorption.
    /// The per-track stage processor further varies timing with pan/depth.
    public func makeProfile() -> StudioRoomAcousticProfile {
        let rt = predictedRT60
        let wallAlpha = wallMaterial.octaveAbsorption[2]
        let treatmentAlpha = wallTreatmentMaterial.octaveAbsorption[2]
        let covered = Self.bounded(treatedWallFraction, low: 0, high: 1, fallback: 0)
        let reflectivity = Float(sqrt(max(0.01, 1 - ((1 - covered) * wallAlpha +
                                                        covered * treatmentAlpha))))
        let soundSpeed = 343.0
        let geometries: [(Double, Float, Float)] = [
            (safeWidth, 0.27, 0.13),
            (safeWidth * 1.22, 0.13, 0.27),
            (safeHeight, -0.14, 0.16),
            (safeLength * 0.65, 0.18, -0.12),
            (safeHeight + safeWidth * 0.60, -0.10, 0.12),
            (safeLength * 1.10, 0.11, 0.13),
            (safeLength + safeWidth * 0.42, -0.08, -0.07)
        ]
        let taps = geometries.map { distance, l, r in
            StudioEarlyReflection(
                delayMilliseconds: Float(min(110, max(3, 1_000 * distance / soundSpeed))),
                leftGain: reflectivity * l,
                rightGain: reflectivity * r
            )
        }
        // Only the custom native room changes network spacing. The octave
        // decay formula alone cannot produce room-size-dependent modal density.
        // Cube-root-of-volume approximates characteristic acoustic distance;
        // bounded scale prevents disproportionate memory use on a MacBook.
        let volumeScale = Float(
            max(0.72, min(1.75, pow(volumeCubicMeters / 1_728.0, 1.0 / 3.0)))
        )

        // Mean high-frequency absorption darkens the early reflection field,
        // while preserving the distinct amplitudes/timing of each image tap.
        // Generic coefficient estimates: not a physical boundary solver.
        let highBand = 5
        let averageHighAbsorption = (
            floorArea * floorMaterial.octaveAbsorption[highBand] +
            floorArea * ceilingMaterial.octaveAbsorption[highBand] +
            wallArea * ((1 - covered) * wallMaterial.octaveAbsorption[highBand] +
                         covered * wallTreatmentMaterial.octaveAbsorption[highBand])
        ) / totalArea
        let reflectionHighCutHz = Float(
            max(1_400, min(16_000, 15_500 - 13_500 * averageHighAbsorption))
        )

        // Studio's FDN is intentionally limited to 0.2...15 s. The UI shows
        // the unbounded formula result; only the synthesizer clamps the target.
        let target = rt.map { Float(max(0.2, min(15, $0))) }
        // Short, spectrally uneven rooms expose cross-band feedback leakage.
        // Opt into the bounded, precomputed feedback fit only here; every
        // other custom room retains its previously calibrated native sound.
        let requiresShortRoomCalibration =
            rt[2] < 0.70 && rt[4] < 0.55 && rt[0] > 2 * rt[2]
        return StudioRoomAcousticProfile(
            id: Self.profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Custom Acoustic Room" : name,
            bassRT60: target[1], midRT60: target[2], trebleRT60: target[4],
            earlyReflections: taps,
            sixBandRT60: target,
            shortRoomFeedbackCalibration: requiresShortRoomCalibration,
            lateDelayScale: volumeScale,
            earlyReflectionHighCutHz: reflectionHighCutHz
        )
    }
}
