import Foundation

/// Coordinate system shared by future instrument-to-microphone routing.
/// x: left (-) / right (+), centered within the room
/// y: distance into the stage from its front wall (0 ... room length)
/// z: height above floor (0 ... room height), all in meters.
public struct StudioRoomPosition3D: Codable, Equatable, Sendable {
    public var xMeters: Double
    public var yMeters: Double
    public var zMeters: Double

    public init(xMeters: Double = 0, yMeters: Double = 2,
                zMeters: Double = 2.5) {
        self.xMeters = xMeters
        self.yMeters = yMeters
        self.zMeters = zMeters
    }

    public func clamped(to room: StudioAcousticRoomDesign) -> Self {
        func bound(_ value: Double, _ minimum: Double,
                   _ maximum: Double, fallback: Double) -> Double {
            value.isFinite ? min(maximum, max(minimum, value)) : fallback
        }
        return Self(
            xMeters: bound(xMeters, -room.safeWidth / 2,
                           room.safeWidth / 2, fallback: 0),
            yMeters: bound(yMeters, 0, room.safeLength, fallback: 0),
            zMeters: bound(zMeters, 0, room.safeHeight,
                           fallback: min(2.5, room.safeHeight))
        )
    }
}

/// Signed pressure-response patterns. A negative value means a phase-inverted
/// rear lobe, as for an ideal figure-eight. This is an idealized polar model,
/// not a particular manufacturer's microphone or a frequency-dependent capsule.
public enum StudioMicrophonePolarPattern: String, Codable, CaseIterable,
                                           Identifiable, Sendable {
    case omnidirectional
    case cardioid
    case supercardioid
    case hypercardioid
    case figureEight

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .omnidirectional: return "Omnidirectional"
        case .cardioid: return "Cardioid"
        case .supercardioid: return "Supercardioid"
        case .hypercardioid: return "Hypercardioid"
        case .figureEight: return "Figure-8"
        }
    }

    /// cosine = 1 in front of the capsule, -1 directly behind.
    public func signedResponse(cosine: Double) -> Double {
        let c = cosine.isFinite ? min(1, max(-1, cosine)) : 0
        switch self {
        case .omnidirectional: return 1
        case .cardioid: return 0.5 + 0.5 * c
        case .supercardioid: return 0.37 + 0.63 * c
        case .hypercardioid: return 0.25 + 0.75 * c
        case .figureEight: return c
        }
    }
}

/// One independently movable microphone, including those created by an array.
/// An array shares a group ID but has individually editable capsules.
public struct StudioVirtualMicrophone: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var position: StudioRoomPosition3D
    /// 0 faces toward +y (the rear of the stage); +90 faces right (+x).
    public var azimuthDegrees: Double
    /// +90 points at the ceiling, -90 at the floor.
    public var elevationDegrees: Double
    public var pattern: StudioMicrophonePolarPattern
    public var arrayID: UUID?
    public var arrayName: String?
    /// Nil means the default channel settings; preserves old saved capsules.
    public var mixerSettings: StudioMicrophoneChannelSettings?

    public var mixer: StudioMicrophoneChannelSettings {
        mixerSettings ?? StudioMicrophoneChannelSettings()
    }

    public init(id: UUID = UUID(), name: String = "Spot Microphone",
                position: StudioRoomPosition3D = .init(),
                azimuthDegrees: Double = 0, elevationDegrees: Double = 0,
                pattern: StudioMicrophonePolarPattern = .cardioid,
                arrayID: UUID? = nil, arrayName: String? = nil,
                mixerSettings: StudioMicrophoneChannelSettings? = nil) {
        self.id = id
        self.name = name
        self.position = position
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.pattern = pattern
        self.arrayID = arrayID
        self.arrayName = arrayName
        self.mixerSettings = mixerSettings
    }

    public func clamped(to room: StudioAcousticRoomDesign) -> Self {
        var copy = self
        copy.position = position.clamped(to: room)
        copy.azimuthDegrees = azimuthDegrees.isFinite ?
            min(180, max(-180, azimuthDegrees)) : 0
        copy.elevationDegrees = elevationDegrees.isFinite ?
            min(90, max(-90, elevationDegrees)) : 0
        return copy
    }
}

public enum StudioMicrophoneArrayPreset: String, CaseIterable,
                                          Identifiable, Sendable {
    case spot
    case xyPair
    case ortfPair
    case deccaTree

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .spot: return "Single Spot"
        case .xyPair: return "XY Stereo Pair"
        case .ortfPair: return "ORTF Stereo Pair"
        case .deccaTree: return "Decca Tree"
        }
    }

    public var microphoneCount: Int {
        switch self {
        case .spot: return 1
        case .xyPair, .ortfPair: return 2
        case .deccaTree: return 3
        }
    }

    /// Factory placements use real meter separations. These are editable
    /// starting layouts, not licensed mic recordings or complete simulations
    /// of real microphone hardware and hall acoustics.
    public func makeMicrophones(in room: StudioAcousticRoomDesign,
                                center: StudioRoomPosition3D? = nil)
        -> [StudioVirtualMicrophone] {
        let origin = (center ?? StudioRoomPosition3D(
            xMeters: 0, yMeters: room.safeLength * 0.2,
            zMeters: min(3, room.safeHeight * 0.75)
        )).clamped(to: room)
        let groupID = UUID()

        func mic(_ suffix: String, dx: Double, dy: Double, yaw: Double,
                 pattern: StudioMicrophonePolarPattern,
                 pan: Float = 0) -> StudioVirtualMicrophone {
            StudioVirtualMicrophone(
                name: "\(displayName) — \(suffix)",
                position: StudioRoomPosition3D(
                    xMeters: origin.xMeters + dx,
                    yMeters: origin.yMeters + dy,
                    zMeters: origin.zMeters
                ).clamped(to: room),
                azimuthDegrees: yaw, pattern: pattern,
                arrayID: groupID, arrayName: displayName,
                mixerSettings: StudioMicrophoneChannelSettings(pan: pan)
            )
        }

        switch self {
        case .spot:
            return [mic("Spot", dx: 0, dy: 0, yaw: 0, pattern: .cardioid)]
        case .xyPair:
            return [
                mic("Left", dx: 0, dy: 0, yaw: -45, pattern: .cardioid, pan: -0.7),
                mic("Right", dx: 0, dy: 0, yaw: 45, pattern: .cardioid, pan: 0.7)
            ]
        case .ortfPair:
            return [
                mic("Left", dx: -0.085, dy: 0, yaw: -55, pattern: .cardioid, pan: -0.7),
                mic("Right", dx: 0.085, dy: 0, yaw: 55, pattern: .cardioid, pan: 0.7)
            ]
        case .deccaTree:
            return [
                mic("Left", dx: -1, dy: 0, yaw: 0, pattern: .omnidirectional, pan: -0.8),
                mic("Center", dx: 0, dy: 0.75, yaw: 0, pattern: .omnidirectional, pan: 0),
                mic("Right", dx: 1, dy: 0, yaw: 0, pattern: .omnidirectional, pan: 0.8)
            ]
        }
    }
}

/// Geometry-only result of one source feeding one virtual microphone.
/// No audio is routed yet: the next milestone will use the same calculations
/// in a bounded, preallocated microphone/source matrix.
public struct StudioMicrophoneCaptureGeometry: Equatable, Sendable {
    public let distanceMeters: Double
    public let propagationDelayMilliseconds: Double
    public let signedPolarResponse: Double
    public let estimatedDirectAmplitude: Double
}

public enum StudioMicrophoneGeometry {
    public static let speedOfSoundMetersPerSecond = 343.0

    public static func capture(source: StudioRoomPosition3D,
                               microphone: StudioVirtualMicrophone)
        -> StudioMicrophoneCaptureGeometry {
        let dx = source.xMeters - microphone.position.xMeters
        let dy = source.yMeters - microphone.position.yMeters
        let dz = source.zMeters - microphone.position.zMeters
        let distance = max(0, sqrt(dx * dx + dy * dy + dz * dz))
        guard distance.isFinite else {
            return StudioMicrophoneCaptureGeometry(
                distanceMeters: 0, propagationDelayMilliseconds: 0,
                signedPolarResponse: 0, estimatedDirectAmplitude: 0
            )
        }
        let yaw = microphone.azimuthDegrees * Double.pi / 180
        let pitch = microphone.elevationDegrees * Double.pi / 180
        let facingX = sin(yaw) * cos(pitch)
        let facingY = cos(yaw) * cos(pitch)
        let facingZ = sin(pitch)
        let cosine = distance > 0.00001 ?
            (dx * facingX + dy * facingY + dz * facingZ) / distance : 1
        let pickup = microphone.pattern.signedResponse(cosine: cosine)
        // 1m-reference inverse-distance law, near-field capped; gentle
        // broadband air-loss proxy. Later DSP will add frequency dependence,
        // reflection paths and room-specific occlusion.
        let radial = 1 / max(1, distance)
        let attenuation = exp(-0.003 * distance)
        return StudioMicrophoneCaptureGeometry(
            distanceMeters: distance,
            propagationDelayMilliseconds: 1_000 * distance /
                speedOfSoundMetersPerSecond,
            signedPolarResponse: pickup,
            estimatedDirectAmplitude: pickup * radial * attenuation
        )
    }

    /// Temporary source-position adapter for existing 2D Stage tracks.
    /// Stage zones are not true measured coordinates; this is a consistent
    /// bridge for the future native microphone/spill routing engine.
    public static func approximateTrackPosition(pan: Float, zone: Int,
                                                 room: StudioAcousticRoomDesign)
        -> StudioRoomPosition3D {
        let safePan = pan.isFinite ? min(1, max(-1, Double(pan))) : 0
        let safeZone = min(5, max(0, zone))
        let yFraction = safeZone == 0 ? 0.06 : 0.16 + 0.15 * Double(safeZone - 1)
        return StudioRoomPosition3D(
            xMeters: safePan * room.safeWidth * 0.42,
            yMeters: room.safeLength * yFraction,
            zMeters: min(room.safeHeight, 1.3)
        )
    }
}
