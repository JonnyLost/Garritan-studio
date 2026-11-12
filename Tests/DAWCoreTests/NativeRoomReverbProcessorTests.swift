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
        XCTAssertEqual(profiles.count, 3)
        XCTAssertEqual(profiles[0].midRT60, 2.2, accuracy: 0.001)
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
