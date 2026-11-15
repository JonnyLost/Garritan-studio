import XCTest
@testable import DAWCore

final class NativeRoomReverbProcessorTests: XCTestCase {
    private func impulse(_ processor: NativeRoomReverbProcessor, frames: Int,
                         chunkSize: Int) -> ([Float], [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < frames {
                    let length = min(chunkSize, frames - offset)
                    processor.process(left: l.baseAddress!.advanced(by: offset),
                                      right: r.baseAddress!.advanced(by: offset),
                                      frameCount: length)
                    offset += length
                }
            }
        }
        return (left, right)
    }

    func testPresetProfilesRoundTripThroughJSON() throws {
        let profiles = StudioRoomAcousticProfile.starterProfiles
        let data = try JSONEncoder().encode(profiles)
        XCTAssertEqual(try JSONDecoder().decode([StudioRoomAcousticProfile].self, from: data), profiles)
        XCTAssertEqual(profiles.count, 4)
        XCTAssertEqual(profiles[0].midRT60, 2.2, accuracy: 0.001)
    }

    func testRoomSelectionMapsStableIDsToParameters() {
        let profiles = StudioRoomAcousticProfile.starterProfiles
        XCTAssertEqual(StudioRoomAcousticProfile.index(forID: profiles[0].id), 0)
        XCTAssertEqual(StudioRoomAcousticProfile.index(forID: profiles[1].id), 1)
        XCTAssertEqual(StudioRoomAcousticProfile.index(forID: profiles[2].id), 2)
        XCTAssertNil(StudioRoomAcousticProfile.index(forID: "unknown"))
        XCTAssertGreaterThan(profiles[0].midRT60, profiles[1].midRT60)
        XCTAssertGreaterThan(profiles[2].midRT60, profiles[1].midRT60)
    }

    func testNativeRoomChoicePersistsInDAWStateAndOldProjectsLoad() throws {
        var state = DAWState()
        state.acousticRoomProfileID = StudioRoomAcousticProfile.mgmSonyScoringInspired.id
        let encoded = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(DAWState.self, from: encoded)
        XCTAssertEqual(restored.acousticRoomProfileID, state.acousticRoomProfileID)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "acousticRoomProfileID")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedOld = try JSONDecoder().decode(DAWState.self, from: oldData)
        XCTAssertNil(decodedOld.acousticRoomProfileID)
    }

    func testPresetSwitchKeepsExistingTailAndIgnoresInvalidSelection() {
        let processor = NativeRoomReverbProcessor(
            sampleRate: 48_000, profiles: StudioRoomAcousticProfile.starterProfiles
        )
        var left = [Float](repeating: 0, count: 48_000)
        var right = left
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                processor.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: 48_000)
            }
        }
        processor.selectProfile(at: 1)
        XCTAssertEqual(processor.selectedProfileIndex, 1)
        processor.selectProfile(at: 999)
        XCTAssertEqual(processor.selectedProfileIndex, 1)

        var tailL = [Float](repeating: 0, count: 4_096)
        var tailR = tailL
        tailL.withUnsafeMutableBufferPointer { lb in
            tailR.withUnsafeMutableBufferPointer { rb in
                processor.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        XCTAssertGreaterThan(tailL.reduce(0) { $0 + abs($1) }, 0)
        XCTAssertTrue(tailL.allSatisfy(\.isFinite))
        XCTAssertTrue(tailR.allSatisfy(\.isFinite))
    }

    func testDryScoringStageHasFasterLateEnergyDecayThanLivelyStage() {
        let rate = 44_100
        let frames = rate * 3
        let lively = impulse(NativeRoomReverbProcessor(sampleRate: Double(rate),
                              profile: .abbeyRoadStudioOne), frames: frames, chunkSize: 512)
        let dry = impulse(NativeRoomReverbProcessor(sampleRate: Double(rate),
                            profile: .mgmSonyScoringInspired), frames: frames, chunkSize: 512)
        func lateEnergy(_ channels: ([Float], [Float])) -> Double {
            (rate * 2..<frames).reduce(0) { accumulator, sample in
                let l = Double(channels.0[sample])
                let r = Double(channels.1[sample])
                return accumulator + l * l + r * r
            }
        }
        let livelyEnergy = lateEnergy(lively)
        let dryEnergy = lateEnergy(dry)
        XCTAssertGreaterThan(livelyEnergy, 0)
        XCTAssertLessThan(dryEnergy, livelyEnergy * 0.25)
    }

    func testBandDependentDecayProducesLongerBassThanTrebleTail() {
        // This is a spectral behavior test, not a claim of measured venue RT60.
        var room = StudioRoomAcousticProfile.abbeyRoadStudioOne
        room.bassRT60 = 4
        room.midRT60 = 1.2
        room.trebleRT60 = 0.35
        let sampleRate = 44_100
        let (left, right) = impulse(
            NativeRoomReverbProcessor(sampleRate: Double(sampleRate), profile: room),
            frames: sampleRate * 3, chunkSize: 256
        )
        let lowCoefficient = Float(1 - exp(-2 * Double.pi * 250 / Double(sampleRate)))
        let highCoefficient = Float(1 - exp(-2 * Double.pi * 2500 / Double(sampleRate)))
        var lowState: Float = 0
        var highState: Float = 0
        var lowEnergy = [Double](repeating: 0, count: 3)
        var highEnergy = [Double](repeating: 0, count: 3)

        for i in left.indices {
            let sample = (left[i] + right[i]) * 0.5
            lowState += lowCoefficient * (sample - lowState)
            highState += highCoefficient * (sample - highState)
            let low = Double(lowState)
            let high = Double(sample - highState)
            let segment = i / sampleRate
            lowEnergy[segment] += low * low
            highEnergy[segment] += high * high
        }

        XCTAssertGreaterThan(lowEnergy[0], 0)
        XCTAssertGreaterThan(highEnergy[0], 0)
        let lowRetention = lowEnergy[2] / lowEnergy[0]
        let highRetention = highEnergy[2] / highEnergy[0]
        XCTAssertGreaterThan(lowRetention, highRetention * 100)
    }

    func testWetOnlyImpulseHasNoImmediateDryLeak() {
        let frames = 12_000
        let (left, right) = impulse(NativeRoomReverbProcessor(sampleRate: 48_000),
                                    frames: frames, chunkSize: 128)
        XCTAssertTrue(left.prefix(480).allSatisfy { $0 == 0 })
        XCTAssertTrue(right.prefix(480).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(left.dropFirst(600).reduce(Float(0)) { $0 + abs($1) }, 0.1)
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(zip(left, right).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }, 0.01)
    }

    func testDifferentBufferSizesProduceSameResult() {
        let frames = 10_000
        let (oneL, oneR) = impulse(NativeRoomReverbProcessor(sampleRate: 44_100),
                                   frames: frames, chunkSize: frames)
        let (manyL, manyR) = impulse(NativeRoomReverbProcessor(sampleRate: 44_100),
                                     frames: frames, chunkSize: 47)
        XCTAssertEqual(oneL, manyL)
        XCTAssertEqual(oneR, manyR)
    }

    func testInvalidProfileValuesCannotCreateNonFiniteFeedback() {
        let corrupted = StudioRoomAcousticProfile(
            id: "bad", name: "bad", bassRT60: .nan, midRT60: -999,
            trebleRT60: .infinity,
            earlyReflections: [.init(delayMilliseconds: .infinity, leftGain: 1, rightGain: 1),
                               .init(delayMilliseconds: 1_000_000, leftGain: 999, rightGain: -999)])
        let (left, right) = impulse(NativeRoomReverbProcessor(sampleRate: .nan, profile: corrupted),
                                    frames: 8_000, chunkSize: 512)
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
    }

    func testTailDecaysInsteadOfIncreasingIndefinitely() {
        let rate = 48_000
        let (left, right) = impulse(NativeRoomReverbProcessor(sampleRate: Double(rate)),
                                    frames: rate * 3, chunkSize: 512)
        func energy(from start: Int, to end: Int) -> Double {
            (start..<end).reduce(0) { total, index in
                let l = Double(left[index]), r = Double(right[index])
                return total + l * l + r * r
            }
        }
        let early = energy(from: rate / 10, to: rate / 2)
        let late = energy(from: rate * 2, to: rate * 3)
        XCTAssertGreaterThan(early, 0)
        XCTAssertLessThan(late, early * 0.1)
    }
}
