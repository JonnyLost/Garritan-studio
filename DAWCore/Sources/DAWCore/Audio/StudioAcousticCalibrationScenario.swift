import Foundation

/// Deterministic synthetic calibration cases. These are original Studio
/// designs, NOT architectural surveys or measurements of named real rooms.
/// Keep them outside app state: they are test fixtures for offline tuning.
public struct StudioAcousticCalibrationScenario: Sendable {
    public let id: String
    public let design: StudioAcousticRoomDesign

    public init(id: String, design: StudioAcousticRoomDesign) {
        self.id = id
        self.design = design
    }

    /// Contrasting geometry and treatment conditions. The existing default
    /// room is deliberately omitted and is used as an independent check.
    public static let contrastingRooms: [StudioAcousticCalibrationScenario] = [
        .init(
            id: "small-treated",
            design: StudioAcousticRoomDesign(
                name: "Small Treated Studio",
                lengthMeters: 7, widthMeters: 5, heightMeters: 3.2,
                wallMaterial: .paintedPlaster, floorMaterial: .heavyCarpet,
                ceilingMaterial: .paintedPlaster,
                treatedWallFraction: 0.55,
                wallTreatmentMaterial: .acousticPanel,
                method: .eyring
            )
        ),
        .init(
            id: "medium-wood",
            design: StudioAcousticRoomDesign(
                name: "Medium Wood Scoring Room",
                lengthMeters: 16, widthMeters: 11, heightMeters: 7,
                wallMaterial: .wood, floorMaterial: .wood,
                ceilingMaterial: .paintedPlaster,
                treatedWallFraction: 0.12,
                wallTreatmentMaterial: .heavyCurtain,
                method: .eyring
            )
        ),
        .init(
            id: "large-reflective",
            design: StudioAcousticRoomDesign(
                name: "Large Reflective Hall",
                lengthMeters: 30, widthMeters: 22, heightMeters: 12,
                wallMaterial: .brick, floorMaterial: .wood,
                ceilingMaterial: .paintedPlaster,
                treatedWallFraction: 0,
                wallTreatmentMaterial: .acousticPanel,
                method: .eyring
            )
        )
    ]

    public static var defaultDesign: StudioAcousticCalibrationScenario {
        .init(id: "default-holdout", design: StudioAcousticRoomDesign())
    }
}
