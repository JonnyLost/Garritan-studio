import Foundation
import XCTest
@testable import DAWCore

final class StudioAcousticRoomDesignerTests: XCTestCase {
    func testRoomGeometryAndSurfaceAreas() {
        let room = StudioAcousticRoomDesign(lengthMeters: 10,
                                            widthMeters: 8, heightMeters: 4)
        XCTAssertEqual(room.volumeCubicMeters, 320, accuracy: 0.001)
        XCTAssertEqual(room.floorArea, 80, accuracy: 0.001)
        XCTAssertEqual(room.wallArea, 144, accuracy: 0.001)
        XCTAssertEqual(room.totalArea, 304, accuracy: 0.001)
    }

    func testSabineSixBandAbsorptionFormula() {
        let room = StudioAcousticRoomDesign(
            lengthMeters: 10, widthMeters: 8, heightMeters: 4,
            wallMaterial: .brick, floorMaterial: .wood,
            ceilingMaterial: .smoothConcrete, method: .sabine
        )
        let expected = 0.161 * 320 /
            (80 * (0.10 + 0.02) + 144 * 0.03)
        XCTAssertEqual(room.predictedRT60.count, 6)
        XCTAssertEqual(room.predictedRT60[2], expected, accuracy: 0.00001)
    }

    func testAbsorptiveTreatmentShortensHighFrequencyDecay() {
        var room = StudioAcousticRoomDesign(
            wallMaterial: .smoothConcrete, floorMaterial: .wood,
            ceilingMaterial: .paintedPlaster, method: .eyring)
        let untreated = room.predictedRT60
        room.wallTreatmentMaterial = .acousticPanel
        room.treatedWallFraction = 0.65
        let treated = room.predictedRT60
        XCTAssertLessThan(treated[4], untreated[4])
        XCTAssertLessThan(treated[5], untreated[5])
        XCTAssertGreaterThan(treated[4], 0)
    }

    func testEyringPredictsShorterThanSabineForHighlyAbsorptiveRoom() {
        var room = StudioAcousticRoomDesign(
            wallMaterial: .acousticPanel, floorMaterial: .heavyCarpet,
            ceilingMaterial: .acousticPanel, method: .sabine)
        let sabine = room.predictedRT60
        room.method = .eyring
        let eyring = room.predictedRT60
        for i in 0..<6 {
            XCTAssertLessThan(eyring[i], sabine[i])
        }
    }

    func testCustomProfileKeepsAllSixBandsAndDimensionBasedReflections() {
        var design = StudioAcousticRoomDesign()
        let first = design.makeProfile()
        XCTAssertEqual(first.id, StudioAcousticRoomDesign.profileID)
        XCTAssertEqual(first.sixBandRT60?.count, 6)
        XCTAssertTrue(first.sixBandRT60!.allSatisfy { $0.isFinite && $0 >= 0.2 && $0 <= 15 })
        design.widthMeters = 20
        let larger = design.makeProfile()
        XCTAssertNotEqual(first.earlyReflections, larger.earlyReflections)
        XCTAssertNotEqual(first.sixBandRT60, larger.sixBandRT60)
    }

    func testFactoryRoomProfilesStillUseLegacyThreeBandDecay() {
        XCTAssertEqual(StudioRoomAcousticProfile.starterProfiles.count, 4)
        XCTAssertTrue(StudioRoomAcousticProfile.starterProfiles.allSatisfy {
            $0.sixBandRT60 == nil
        })
        let playable = StudioRoomAcousticProfile.playableProfiles
        XCTAssertEqual(playable.count, 5)
        XCTAssertEqual(StudioRoomAcousticProfile.index(
            forID: StudioAcousticRoomDesign.profileID), 4)
        XCTAssertNotNil(playable.last?.sixBandRT60)
    }

    func testRoomDesignerPersistsAndLegacyStateWithoutDesignerStillDecodes() throws {
        var state = DAWState()
        state.acousticRoomDesign = StudioAcousticRoomDesign(
            name: "Original Room", lengthMeters: 14, widthMeters: 9,
            heightMeters: 6, wallMaterial: .glass, floorMaterial: .heavyCarpet,
            ceilingMaterial: .wood, treatedWallFraction: 0.3,
            wallTreatmentMaterial: .heavyCurtain, method: .sabine)
        state.acousticRoomProfileID = StudioAcousticRoomDesign.profileID

        let json = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DAWState.self, from: json)
        XCTAssertEqual(decoded.acousticRoomDesign, state.acousticRoomDesign)
        XCTAssertEqual(decoded.acousticRoomProfileID, state.acousticRoomProfileID)

        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: json)
                                       as? [String: Any])
        dictionary.removeValue(forKey: "acousticRoomDesign")
        let older = try JSONSerialization.data(withJSONObject: dictionary)
        XCTAssertNil(try JSONDecoder().decode(DAWState.self, from: older)
                        .acousticRoomDesign)
    }

    func testInvalidDimensionsCannotProduceNaNorCrashDSP() {
        let design = StudioAcousticRoomDesign(
            lengthMeters: .infinity, widthMeters: .nan,
            heightMeters: -10, treatedWallFraction: .infinity)
        XCTAssertEqual(design.volumeCubicMeters, 18 * 12 * 2.2, accuracy: 0.001)
        XCTAssertTrue(design.predictedRT60.allSatisfy { $0.isFinite && $0 > 0 })
        let profile = design.makeProfile()
        let processor = NativeRoomReverbProcessor(sampleRate: 24_000, profile: profile)
        var left = [Float](repeating: 0, count: 4_096)
        var right = left
        left[0] = 1; right[0] = 1
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                processor.process(left: l.baseAddress!, right: r.baseAddress!,
                                  frameCount: l.count)
            }
        }
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
    }

    func testTwoDesignedRoomsGenerateDifferentNativeImpulseTails() {
        var live = StudioAcousticRoomDesign(method: .eyring)
        var dry = live
        dry.ceilingMaterial = .acousticPanel
        dry.wallMaterial = .acousticPanel
        dry.floorMaterial = .heavyCarpet
        live.wallMaterial = .smoothConcrete

        func render(_ profile: StudioRoomAcousticProfile) -> [Float] {
            let processor = NativeRoomReverbProcessor(sampleRate: 24_000,
                                                      profile: profile)
            var left = [Float](repeating: 0, count: 48_000)
            var right = left
            left[0] = 1; right[0] = 1
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    processor.process(left: l.baseAddress!, right: r.baseAddress!,
                                      frameCount: l.count)
                }
            }
            return left
        }
        let liveIR = render(live.makeProfile())
        let dryIR = render(dry.makeProfile())
        let lateLive = liveIR.dropFirst(20_000).reduce(0.0) { $0 + Double($1 * $1) }
        let lateDry = dryIR.dropFirst(20_000).reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertGreaterThan(lateLive, lateDry)
    }
}
