import Foundation
import XCTest
@testable import DAWCore

final class StudioAcousticRoomDesignerTests: XCTestCase {
    func testOnlyStronglyDampedShortRoomsEnableFeedbackCorrection() {
        let scenarios = StudioAcousticCalibrationScenario.contrastingRooms
        XCTAssertEqual(scenarios[0].design.makeProfile().shortRoomFeedbackCalibration, true)
        XCTAssertEqual(scenarios[1].design.makeProfile().shortRoomFeedbackCalibration, false)
        XCTAssertEqual(scenarios[2].design.makeProfile().shortRoomFeedbackCalibration, false)
        XCTAssertEqual(StudioAcousticRoomDesign().makeProfile().shortRoomFeedbackCalibration, false)
        XCTAssertTrue(StudioRoomAcousticProfile.starterProfiles.allSatisfy {
            $0.shortRoomFeedbackCalibration == nil
        })
    }

    func testOfflineShortRoomFeedbackFitIsBoundedAndImprovesSpectralTargets() {
        let room = StudioAcousticCalibrationScenario.contrastingRooms[0].design.makeProfile()
        let targets = room.sixBandRT60!
        let sampleRate = 48_000.0
        let delayFrames = 1_425
        let original = targets.map {
            Float(pow(10.0, -3 * Double(delayFrames) /
                     (sampleRate * Double($0))))
        }
        let corrected = NativeShortRoomFeedbackCalibrator.gains(
            targetRT60: targets, delayFrames: delayFrames, sampleRate: sampleRate
        )
        let desired = original.map(Double.init)
        func error(_ gains: [Float]) -> Double {
            let response = NativeShortRoomFeedbackCalibrator.responseMagnitudes(
                gains: gains, sampleRate: sampleRate)
            return zip(response, desired).reduce(0.0) { partial, pair in
                partial + pow(pair.0 - pair.1, 2)
            }
        }
        XCTAssertEqual(corrected.count, 6)
        XCTAssertTrue(corrected.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 })
        XCTAssertLessThan(error(corrected), error(original))
    }

    func testShortRoomFeedbackFitChangesRealNativeOutputWithoutNonfiniteSamples() {
        var tuned = StudioAcousticCalibrationScenario.contrastingRooms[0].design.makeProfile()
        var baseline = tuned
        baseline.shortRoomFeedbackCalibration = false
        func render(_ room: StudioRoomAcousticProfile) -> [Float] {
            let processor = NativeRoomReverbProcessor(sampleRate: 24_000,
                profiles: [room], includeEarlyReflections: false)
            var l = [Float](repeating: 0, count: 24_000)
            var r = l
            l[0] = 1
            r[0] = 1
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    processor.process(left: lp.baseAddress!, right: rp.baseAddress!,
                                      frameCount: lp.count)
                }
            }
            return l
        }
        let original = render(baseline)
        let corrected = render(tuned)
        XCTAssertNotEqual(original, corrected)
        XCTAssertTrue(corrected.allSatisfy(\.isFinite))
        tuned.shortRoomFeedbackCalibration = true
        XCTAssertEqual(tuned.shortRoomFeedbackCalibration, true)
    }

    func testCalibrationSuiteCoversDistinctRoomTypesAndVolumes() {
        let suite = StudioAcousticCalibrationScenario.contrastingRooms
        XCTAssertEqual(suite.count, 3)
        XCTAssertEqual(Set(suite.map(\.id)).count, suite.count)
        XCTAssertEqual(suite.map(\.id),
                       ["small-treated", "medium-wood", "large-reflective"])

        let small = suite[0].design
        let medium = suite[1].design
        let large = suite[2].design

        XCTAssertLessThan(small.volumeCubicMeters, medium.volumeCubicMeters)
        XCTAssertLessThan(medium.volumeCubicMeters, large.volumeCubicMeters)
        XCTAssertLessThan(small.predictedRT60[3], medium.predictedRT60[3])
        XCTAssertLessThan(medium.predictedRT60[3], large.predictedRT60[3])
        XCTAssertGreaterThan(small.treatedWallFraction, medium.treatedWallFraction)
        XCTAssertEqual(large.treatedWallFraction, 0)
        XCTAssertEqual(small.makeProfile().sixBandRT60?.count, 6)
        XCTAssertEqual(medium.makeProfile().sixBandRT60?.count, 6)
        XCTAssertEqual(large.makeProfile().sixBandRT60?.count, 6)
    }

    func testCalibrationFixturesAreCodableAndDoNotMutateDefaults() throws {
        let base = StudioAcousticCalibrationScenario.defaultDesign.design
        XCTAssertEqual(base, StudioAcousticRoomDesign())
        for scenario in StudioAcousticCalibrationScenario.contrastingRooms {
            let data = try JSONEncoder().encode(scenario.design)
            let decoded = try JSONDecoder().decode(StudioAcousticRoomDesign.self, from: data)
            XCTAssertEqual(decoded, scenario.design)
            XCTAssertTrue(decoded.predictedRT60.allSatisfy { $0.isFinite && $0 > 0 })
        }
        XCTAssertEqual(StudioRoomAcousticProfile.starterProfiles.count, 4)
        XCTAssertTrue(StudioRoomAcousticProfile.starterProfiles.allSatisfy {
            $0.sixBandRT60 == nil && $0.lateDelayScale == nil
        })
    }

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

    func testGeometryChangesLateDelayScaleWithoutChangingFactoryPresets() {
        let small = StudioAcousticRoomDesign(
            lengthMeters: 5, widthMeters: 4, heightMeters: 3).makeProfile()
        let large = StudioAcousticRoomDesign(
            lengthMeters: 35, widthMeters: 25, heightMeters: 12).makeProfile()
        XCTAssertLessThan(small.lateDelayScale ?? 0, large.lateDelayScale ?? 0)
        XCTAssertNotNil(small.lateDelayScale)
        XCTAssertNil(StudioRoomAcousticProfile.abbeyRoadStudioOne.lateDelayScale)
        XCTAssertNil(StudioRoomAcousticProfile.abbeyRoadStudioOne.earlyReflectionHighCutHz)
    }

    func testMaterialsChangeEarlyReflectionHighFrequencyAbsorption() {
        let reflective = StudioAcousticRoomDesign(
            wallMaterial: .smoothConcrete, floorMaterial: .smoothConcrete,
            ceilingMaterial: .smoothConcrete).makeProfile()
        let treated = StudioAcousticRoomDesign(
            wallMaterial: .acousticPanel, floorMaterial: .heavyCarpet,
            ceilingMaterial: .acousticPanel).makeProfile()
        XCTAssertGreaterThan(reflective.earlyReflectionHighCutHz ?? 0,
                             treated.earlyReflectionHighCutHz ?? 0)
    }

    func testMaterialFilteringChangesActualEarlyReflectionAudio() {
        func render(highCut: Float) -> [Float] {
            var room = StudioRoomAcousticProfile.abbeyRoadStudioOne
            room.earlyReflectionHighCutHz = highCut
            let dsp = NativeStageEarlyReflectionProcessor(sampleRate: 48_000,
                                                            profiles: [room])
            dsp.update(roomIndex: 0, pan: 0, zone: 2)
            var l = [Float](repeating: 0, count: 7_000)
            var r = l
            l[0] = 1; r[0] = 1
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    dsp.process(left: lp.baseAddress!, right: rp.baseAddress!,
                                frameCount: lp.count)
                }
            }
            return l
        }
        let bright = render(highCut: 15_000)
        let dark = render(highCut: 1_500)
        XCTAssertNotEqual(bright, dark)
        XCTAssertGreaterThan(bright.map { abs($0) }.max() ?? 0,
                             dark.map { abs($0) }.max() ?? 0)
    }

    func testRoomScaleChangesNativeLateDelayArrival() {
        func render(scale: Float) -> [Float] {
            var profile = StudioRoomAcousticProfile.abbeyRoadStudioOne
            profile.earlyReflections = []
            profile.lateDelayScale = scale
            let dsp = NativeRoomReverbProcessor(sampleRate: 24_000, profile: profile)
            var l = [Float](repeating: 0, count: 10_000)
            var r = l
            l[0] = 1; r[0] = 1
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    dsp.process(left: lp.baseAddress!, right: rp.baseAddress!,
                                frameCount: lp.count)
                }
            }
            return l
        }
        let short = render(scale: 0.72)
        let long = render(scale: 1.5)
        let firstShort = short.firstIndex(where: { abs($0) > 0.00001 }) ?? short.count
        let firstLong = long.firstIndex(where: { abs($0) > 0.00001 }) ?? long.count
        XCTAssertLessThan(firstShort, firstLong)
        XCTAssertTrue(short.allSatisfy(\.isFinite))
        XCTAssertTrue(long.allSatisfy(\.isFinite))
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
