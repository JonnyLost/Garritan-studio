import XCTest
@testable import DAWCore

/// Geometry tests only. The multi-source mic routing audio engine will be
/// introduced after this model/UI milestone and validated independently.
final class StudioVirtualMicrophoneGeometryTests: XCTestCase {
    private let room = StudioAcousticRoomDesign()

    func testArrayTemplatesUseStableCountsAndIndependentIdentities() {
        for preset in StudioMicrophoneArrayPreset.allCases {
            let microphones = preset.makeMicrophones(in: room)
            XCTAssertEqual(microphones.count, preset.microphoneCount)
            XCTAssertEqual(Set(microphones.map(\.id)).count, preset.microphoneCount)
            XCTAssertEqual(Set(microphones.compactMap(\.arrayID)).count, 1)
            XCTAssertTrue(microphones.allSatisfy {
                $0.arrayName == preset.displayName
            })
        }
    }

    func testXYORTFAndDeccaTreeHaveDifferentPhysicalLayouts() {
        let xy = StudioMicrophoneArrayPreset.xyPair.makeMicrophones(in: room)
        XCTAssertEqual(xy[0].position, xy[1].position)
        XCTAssertEqual(xy[0].azimuthDegrees, -45)
        XCTAssertEqual(xy[1].azimuthDegrees, 45)

        let ortf = StudioMicrophoneArrayPreset.ortfPair.makeMicrophones(in: room)
        XCTAssertEqual(ortf[1].position.xMeters - ortf[0].position.xMeters,
                       0.17, accuracy: 1.0e-6)
        XCTAssertEqual(ortf[0].azimuthDegrees, -55)
        XCTAssertEqual(ortf[1].azimuthDegrees, 55)

        let tree = StudioMicrophoneArrayPreset.deccaTree.makeMicrophones(in: room)
        XCTAssertTrue(tree.allSatisfy { $0.pattern == .omnidirectional })
        XCTAssertEqual(tree[2].position.xMeters - tree[0].position.xMeters, 2,
                       accuracy: 1.0e-6)
        XCTAssertEqual(tree[1].position.yMeters - tree[0].position.yMeters, 0.75,
                       accuracy: 1.0e-6)
    }

    func testPolarPatternsTreatFrontAndRearDifferently() {
        XCTAssertEqual(StudioMicrophonePolarPattern.omnidirectional.signedResponse(cosine: 1), 1)
        XCTAssertEqual(StudioMicrophonePolarPattern.omnidirectional.signedResponse(cosine: -1), 1)
        XCTAssertEqual(StudioMicrophonePolarPattern.cardioid.signedResponse(cosine: 1), 1)
        XCTAssertEqual(StudioMicrophonePolarPattern.cardioid.signedResponse(cosine: -1), 0)
        XCTAssertEqual(StudioMicrophonePolarPattern.figureEight.signedResponse(cosine: 1), 1)
        XCTAssertEqual(StudioMicrophonePolarPattern.figureEight.signedResponse(cosine: -1), -1)
        XCTAssertLessThan(
            StudioMicrophonePolarPattern.supercardioid.signedResponse(cosine: -1), 0
        )
        XCTAssertLessThan(
            StudioMicrophonePolarPattern.hypercardioid.signedResponse(cosine: -1), 0
        )
    }

    func testDistanceAndPropagationTimeFollowThreeDimensionalSeparation() {
        let microphone = StudioVirtualMicrophone(
            position: StudioRoomPosition3D(xMeters: 0, yMeters: 0, zMeters: 2),
            pattern: .omnidirectional
        )
        let near = StudioMicrophoneGeometry.capture(
            source: StudioRoomPosition3D(xMeters: 0, yMeters: 1, zMeters: 2),
            microphone: microphone
        )
        let far = StudioMicrophoneGeometry.capture(
            source: StudioRoomPosition3D(xMeters: 0, yMeters: 12, zMeters: 2),
            microphone: microphone
        )
        XCTAssertEqual(near.distanceMeters, 1, accuracy: 1.0e-10)
        XCTAssertEqual(far.distanceMeters, 12, accuracy: 1.0e-10)
        XCTAssertEqual(near.propagationDelayMilliseconds, 1_000 / 343,
                       accuracy: 1.0e-10)
        XCTAssertEqual(far.propagationDelayMilliseconds, 12_000 / 343,
                       accuracy: 1.0e-10)
        XCTAssertGreaterThan(near.estimatedDirectAmplitude,
                             far.estimatedDirectAmplitude)
    }

    func testRearOfCardioidSuppressesSpillWhileOmniCapturesIt() {
        let front = StudioRoomPosition3D(xMeters: 0, yMeters: 4, zMeters: 2)
        let rear = StudioRoomPosition3D(xMeters: 0, yMeters: -4, zMeters: 2)
        var microphone = StudioVirtualMicrophone(
            position: StudioRoomPosition3D(xMeters: 0, yMeters: 0, zMeters: 2),
            azimuthDegrees: 0,
            pattern: .cardioid
        )
        let forward = StudioMicrophoneGeometry.capture(source: front,
                                                        microphone: microphone)
        let backward = StudioMicrophoneGeometry.capture(source: rear,
                                                         microphone: microphone)
        XCTAssertGreaterThan(forward.estimatedDirectAmplitude, 0)
        XCTAssertEqual(backward.estimatedDirectAmplitude, 0, accuracy: 1.0e-10)

        microphone.pattern = .omnidirectional
        let omniRear = StudioMicrophoneGeometry.capture(source: rear,
                                                         microphone: microphone)
        XCTAssertGreaterThan(omniRear.estimatedDirectAmplitude, 0)

        microphone.pattern = .figureEight
        let phaseReversed = StudioMicrophoneGeometry.capture(source: rear,
                                                              microphone: microphone)
        XCTAssertLessThan(phaseReversed.estimatedDirectAmplitude, 0)
    }

    func testAzimuthAndElevationAlterPickup() {
        let source = StudioRoomPosition3D(xMeters: 5, yMeters: 0, zMeters: 2)
        var microphone = StudioVirtualMicrophone(
            position: StudioRoomPosition3D(xMeters: 0, yMeters: 0, zMeters: 2),
            azimuthDegrees: 90, pattern: .cardioid
        )
        let aimed = StudioMicrophoneGeometry.capture(source: source,
                                                      microphone: microphone)
        microphone.azimuthDegrees = -90
        let away = StudioMicrophoneGeometry.capture(source: source,
                                                     microphone: microphone)
        XCTAssertGreaterThan(aimed.estimatedDirectAmplitude, 0)
        XCTAssertEqual(away.estimatedDirectAmplitude, 0, accuracy: 1.0e-9)

        microphone.azimuthDegrees = 0
        microphone.elevationDegrees = 90
        let above = StudioMicrophoneGeometry.capture(
            source: StudioRoomPosition3D(xMeters: 0, yMeters: 0, zMeters: 5),
            microphone: microphone
        )
        XCTAssertGreaterThan(above.estimatedDirectAmplitude, 0)
    }

    func testRoomClampsInvalidAndOutOfBoundsMicrophoneCoordinates() {
        let small = StudioAcousticRoomDesign(
            lengthMeters: 3, widthMeters: 3, heightMeters: 2.2
        )
        let bad = StudioVirtualMicrophone(
            position: StudioRoomPosition3D(
                xMeters: 100, yMeters: -.infinity, zMeters: 25
            ),
            azimuthDegrees: .nan, elevationDegrees: 200
        ).clamped(to: small)
        XCTAssertEqual(bad.position.xMeters, 1.5)
        XCTAssertEqual(bad.position.yMeters, 0)
        XCTAssertEqual(bad.position.zMeters, 2.2)
        XCTAssertEqual(bad.azimuthDegrees, 0)
        XCTAssertEqual(bad.elevationDegrees, 90)
    }

    func testTemplatePositionsStayInsideNarrowRooms() {
        let narrow = StudioAcousticRoomDesign(
            lengthMeters: 3, widthMeters: 3, heightMeters: 2.2
        )
        for preset in StudioMicrophoneArrayPreset.allCases {
            for microphone in preset.makeMicrophones(in: narrow) {
                XCTAssertEqual(microphone.clamped(to: narrow), microphone)
            }
        }
    }

    func testExistingStagePanAndZonesMapToDistinctThreeDPositions() {
        let leftFront = StudioMicrophoneGeometry.approximateTrackPosition(
            pan: -1, zone: 1, room: room)
        let rightBack = StudioMicrophoneGeometry.approximateTrackPosition(
            pan: 1, zone: 5, room: room)
        XCTAssertLessThan(leftFront.xMeters, 0)
        XCTAssertGreaterThan(rightBack.xMeters, 0)
        XCTAssertLessThan(leftFront.yMeters, rightBack.yMeters)
        XCTAssertEqual(leftFront.zMeters, 1.3)
        XCTAssertEqual(rightBack.zMeters, 1.3)
    }

    func testMicrophoneArrayPersistsInProjectAndLegacyStateDecodes() throws {
        var state = DAWState()
        let initial = StudioMicrophoneArrayPreset.deccaTree.makeMicrophones(in: room)
        state.virtualMicrophones = initial
        let saved = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(DAWState.self, from: saved)
        XCTAssertEqual(restored.virtualMicrophones, initial)

        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: saved)
                                  as? [String: Any])
        older.removeValue(forKey: "virtualMicrophones")
        let oldData = try JSONSerialization.data(withJSONObject: older)
        let oldState = try JSONDecoder().decode(DAWState.self, from: oldData)
        XCTAssertNil(oldState.virtualMicrophones)
        XCTAssertNil(DAWState().virtualMicrophones)
    }
}
