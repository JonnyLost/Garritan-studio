import XCTest
@testable import DAWCore

/// Actual rendered synthetic microphone signal tests (not just UI geometry).
final class NativeMicrophoneSpillProcessorTests: XCTestCase {
    private let rate = 48_000.0

    private func impulse(gain: Float = 1, delayMs: Float,
                         alpha: Float = 1, chunkSize: Int = 8_000)
        -> [Float] {
        let processor = NativeMicrophoneSpillProcessor(sampleRate: rate)
        processor.setTargets(gain: gain, delayMilliseconds: delayMs,
                             lowPassAlpha: alpha)
        var l = [Float](repeating: 0, count: 8_000)
        var r = l
        l[0] = 1
        r[0] = 1
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var offset = 0
                while offset < lp.count {
                    let count = min(chunkSize, lp.count - offset)
                    processor.process(
                        left: lp.baseAddress!.advanced(by: offset),
                        right: rp.baseAddress!.advanced(by: offset),
                        frameCount: count
                    )
                    offset += count
                }
            }
        }
        XCTAssertEqual(l, r)
        return l
    }

    func testSoundArrivesAfterPhysicalDelayNotAtFrameZero() {
        let delayed = impulse(delayMs: 10)
        XCTAssertTrue(delayed[..<480].allSatisfy { abs($0) < 1.0e-6 })
        XCTAssertEqual(delayed[480], 1, accuracy: 0.0001)
        XCTAssertEqual(delayed[0], 0)
        let farther = impulse(delayMs: 25)
        XCTAssertTrue(farther[..<1200].allSatisfy { abs($0) < 1.0e-6 })
        XCTAssertGreaterThan(farther[1200], 0.99)
    }

    func testSignedRearLobeRetainsNegativePressure() {
        let negative = impulse(gain: -0.6, delayMs: 5)
        XCTAssertEqual(negative[240], -0.6, accuracy: 0.0001)
        XCTAssertTrue(negative.allSatisfy(\.isFinite))
    }

    func testCaptureOutputIndependentOfBlockSize() {
        let whole = impulse(delayMs: 18.25, alpha: 0.75, chunkSize: 8_000)
        let chunks = impulse(delayMs: 18.25, alpha: 0.75, chunkSize: 37)
        XCTAssertEqual(whole, chunks)
    }

    func testFractionalSampleDelayInterpolateWithoutChangingPolarity() {
        let halfFrame = 0.5 * 1000.0 / rate
        let samples = impulse(gain: -1, delayMs: Float(halfFrame))
        XCTAssertEqual(samples[0], -0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[1], -0.5, accuracy: 0.0001)
        XCTAssertTrue(samples.dropFirst(2).allSatisfy { abs($0) < 1.0e-6 })
    }

    func testMutedSourceDoesNotLeakIntoMicrophone() {
        let muted = impulse(gain: 0, delayMs: 12)
        XCTAssertTrue(muted.allSatisfy { $0 == 0 })
    }

    func testDistanceDampingReducesHighFrequency() {
        let wide = impulse(delayMs: 0, alpha: 1)
        let dull = impulse(delayMs: 0, alpha: 0.18)
        XCTAssertGreaterThan(wide[0], dull[0])
        XCTAssertTrue(dull.allSatisfy(\.isFinite))
    }

    func testVolumeFadeAndMovingMicrophoneRemainFinite() {
        let dsp = NativeMicrophoneSpillProcessor(sampleRate: rate)
        dsp.setTargets(gain: 0.8, delayMilliseconds: 5, lowPassAlpha: 0.8)
        var left = [Float](repeating: 0.6, count: 12_000)
        var right = left
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                dsp.process(left: lp.baseAddress!, right: rp.baseAddress!,
                            frameCount: 4_000)
                dsp.setTargets(gain: 0, delayMilliseconds: 50,
                               lowPassAlpha: 0.05)
                dsp.process(left: lp.baseAddress!.advanced(by: 4_000),
                            right: rp.baseAddress!.advanced(by: 4_000),
                            frameCount: 8_000)
            }
        }
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
        XCTAssertLessThan(abs(left.last ?? 1), 0.01)
    }

    func testExtremeParametersAreBoundedAndDoNotExplode() {
        let dsp = NativeMicrophoneSpillProcessor(sampleRate: .nan)
        dsp.setTargets(gain: .infinity, delayMilliseconds: .nan,
                       lowPassAlpha: -.infinity)
        var l = [Float](repeating: 0.9, count: 2_000)
        var r = l
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                dsp.process(left: lp.baseAddress!, right: rp.baseAddress!,
                            frameCount: lp.count)
            }
        }
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
    }
}

final class StudioMicrophoneMixerStateTests: XCTestCase {
    func testMixerSettingsPersistAndOlderMicrophonesRemainReadable() throws {
        var mic = StudioVirtualMicrophone()
        mic.mixerSettings = StudioMicrophoneChannelSettings(
            level: 1.2, pan: -0.65, isMuted: false, isSolo: true
        )
        let data = try JSONEncoder().encode(mic)
        let restored = try JSONDecoder().decode(
            StudioVirtualMicrophone.self, from: data
        )
        XCTAssertEqual(restored, mic)
        XCTAssertEqual(restored.mixer.safeLevel, 1.2, accuracy: 0.0001)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data)
                                    as? [String: Any])
        legacy.removeValue(forKey: "mixerSettings")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try JSONDecoder().decode(
            StudioVirtualMicrophone.self, from: oldData
        )
        XCTAssertNil(old.mixerSettings)
        XCTAssertEqual(old.mixer.safeLevel, 0.65, accuracy: 0.0001)
    }

    func testMicrophoneAlignmentPersistsWithoutBreakingLegacyProjects() throws {
        var microphone = StudioVirtualMicrophone()
        microphone.mixerSettings = StudioMicrophoneChannelSettings(
            alignmentMilliseconds: -4.5
        )
        let encoded = try JSONEncoder().encode(microphone)
        let restored = try JSONDecoder().decode(
            StudioVirtualMicrophone.self, from: encoded
        )
        XCTAssertEqual(restored.mixer.safeAlignmentMilliseconds,
                       -4.5, accuracy: 0.0001)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var mixer = try XCTUnwrap(object["mixerSettings"] as? [String: Any])
        mixer.removeValue(forKey: "alignmentMilliseconds")
        object["mixerSettings"] = mixer
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(
            StudioVirtualMicrophone.self, from: legacyData
        )
        XCTAssertEqual(legacy.mixer.safeAlignmentMilliseconds, 0)
    }

    func testManualAlignmentIsBoundedAndFinite() {
        XCTAssertEqual(StudioMicrophoneChannelSettings(
            alignmentMilliseconds: .nan
        ).safeAlignmentMilliseconds, 0)
        XCTAssertEqual(StudioMicrophoneChannelSettings(
            alignmentMilliseconds: 100
        ).safeAlignmentMilliseconds, 20)
        XCTAssertEqual(StudioMicrophoneChannelSettings(
            alignmentMilliseconds: -100
        ).safeAlignmentMilliseconds, -20)
    }

    func testPanDefaultsReflectRealMicArrays() {
        let room = StudioAcousticRoomDesign()
        let xy = StudioMicrophoneArrayPreset.xyPair.makeMicrophones(in: room)
        XCTAssertLessThan(xy[0].mixer.safePan, 0)
        XCTAssertGreaterThan(xy[1].mixer.safePan, 0)

        let tree = StudioMicrophoneArrayPreset.deccaTree.makeMicrophones(in: room)
        XCTAssertLessThan(tree[0].mixer.safePan, 0)
        XCTAssertEqual(tree[1].mixer.safePan, 0)
        XCTAssertGreaterThan(tree[2].mixer.safePan, 0)
    }

    func testMicLevelAndPanRejectNonfiniteValues() {
        let state = StudioMicrophoneChannelSettings(level: .nan,
                                                     pan: .infinity)
        XCTAssertEqual(state.safeLevel, 0.65)
        XCTAssertEqual(state.safePan, 0)
        let boosted = StudioMicrophoneChannelSettings(level: 100, pan: -8)
        XCTAssertEqual(boosted.safeLevel, 2)
        XCTAssertEqual(boosted.safePan, -1)
    }
}
