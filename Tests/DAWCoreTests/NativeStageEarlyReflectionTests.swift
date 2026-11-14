import XCTest
@testable import DAWCore

final class NativeStageEarlyReflectionTests: XCTestCase {
    private func impulse(pan: Float, zone: Int, profile: Int = 0,
                         chunkSize: Int = 333) -> ([Float], [Float]) {
        let processor = NativeStageEarlyReflectionProcessor(sampleRate: 48_000)
        processor.update(roomIndex: profile, pan: pan, zone: zone)
        let frames = 9_000
        var left = [Float](repeating: 0, count: frames)
        var right = left
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                guard let l = lb.baseAddress, let r = rb.baseAddress else { return }
                var offset = 0
                while offset < frames {
                    let n = min(chunkSize, frames - offset)
                    processor.process(left: l.advanced(by: offset),
                                      right: r.advanced(by: offset), frameCount: n)
                    offset += n
                }
            }
        }
        return (left, right)
    }

    private func firstArrival(_ samples: [Float]) -> Int {
        samples.firstIndex(where: { abs($0) > 0.00001 }) ?? samples.count
    }

    func testConductorZoneRemainsWetSilent() {
        let (l, r) = impulse(pan: 0, zone: 0)
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
        XCTAssertTrue(r.allSatisfy { $0 == 0 })
    }

    func testDifferentStagePositionsChangeStereoEarlyTiming() {
        let center = impulse(pan: 0, zone: 2)
        let left = impulse(pan: -0.8, zone: 2)
        let right = impulse(pan: 0.8, zone: 2)
        XCTAssertNotEqual(center.0, left.0)
        XCTAssertNotEqual(center.1, left.1)
        XCTAssertLessThan(firstArrival(left.0), firstArrival(right.0))
        XCTAssertGreaterThan(firstArrival(left.1), firstArrival(right.1))
    }

    func testBackRowFirstReflectionIsLaterThanFrontRow() {
        let front = impulse(pan: 0, zone: 1)
        let back = impulse(pan: 0, zone: 5)
        XCTAssertGreaterThan(firstArrival(back.0), firstArrival(front.0))
        XCTAssertTrue(back.0.allSatisfy(\.isFinite))
    }

    func testRoomProfilesProduceDistinctReflections() {
        let dry = impulse(pan: 0.2, zone: 3, profile: 1)
        let live = impulse(pan: 0.2, zone: 3, profile: 0)
        XCTAssertLessThan(firstArrival(dry.0), firstArrival(live.0))
    }

    func testFrameChunkSizeDoesNotChangeEarlyReflections() {
        let a = impulse(pan: -0.3, zone: 4, chunkSize: 9_000)
        let b = impulse(pan: -0.3, zone: 4, chunkSize: 31)
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, b.1)
    }

    func testInvalidParametersClampToSafeValues() {
        let processor = NativeStageEarlyReflectionProcessor(sampleRate: .nan)
        processor.update(roomIndex: 2_000, pan: .nan, zone: 1_000)
        XCTAssertEqual(processor.roomIndex, 0)
        XCTAssertEqual(processor.pan, 0)
        XCTAssertEqual(processor.zone, 5)
        var left = [Float](repeating: 0, count: 3_000)
        var right = left
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                processor.process(left: l.baseAddress!, right: r.baseAddress!,
                                  frameCount: l.count)
            }
        }
        XCTAssertTrue(left.allSatisfy(\.isFinite))
    }
}

final class StudioVirtualMicrophoneTests: XCTestCase {
    private func render(perspective: Int, width: Float) -> ([Float], [Float]) {
        let processor = NativeStageEarlyReflectionProcessor(sampleRate: 48_000)
        processor.update(roomIndex: 0, pan: 0.35, zone: 3,
                         microphonePerspective: perspective,
                         microphoneWidth: width)
        let frames = 10_000
        var left = [Float](repeating: 0, count: frames)
        var right = left
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                processor.process(left: l.baseAddress!, right: r.baseAddress!,
                                  frameCount: l.count)
            }
        }
        return (left, right)
    }

    private func firstArrival(_ channel: [Float]) -> Int {
        channel.firstIndex(where: { abs($0) > 0.00001 }) ?? channel.count
    }

    func testListeningPositionsShiftEarlyReflectionArrival() {
        let close = render(perspective: 0, width: 1)
        let mainPair = render(perspective: 1, width: 1)
        let audience = render(perspective: 2, width: 1)
        XCTAssertLessThan(firstArrival(close.0), firstArrival(mainPair.0))
        XCTAssertLessThan(firstArrival(mainPair.0), firstArrival(audience.0))
    }

    func testZeroWidthCentersStereoReflectionsWithoutChangingRoomSelection() {
        let mono = render(perspective: 1, width: 0)
        let wide = render(perspective: 1, width: 1.4)
        XCTAssertEqual(mono.0, mono.1)
        XCTAssertNotEqual(wide.0, wide.1)
        XCTAssertTrue(wide.0.allSatisfy(\.isFinite))
        XCTAssertTrue(wide.1.allSatisfy(\.isFinite))
    }

    func testDefaultMicrophonePreservesPreviouslyUsedProcessorOutput() {
        let a = NativeStageEarlyReflectionProcessor(sampleRate: 48_000)
        let b = NativeStageEarlyReflectionProcessor(sampleRate: 48_000)
        a.update(roomIndex: 0, pan: -0.3, zone: 4)
        b.update(roomIndex: 0, pan: -0.3, zone: 4,
                 microphonePerspective: 0, microphoneWidth: 1)
        var la = [Float](repeating: 0, count: 8_000)
        var ra = la
        var lb = la
        var rb = la
        la[0] = 1; ra[0] = 1; lb[0] = 1; rb[0] = 1
        la.withUnsafeMutableBufferPointer { l in
            ra.withUnsafeMutableBufferPointer { r in
                a.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: l.count)
            }
        }
        lb.withUnsafeMutableBufferPointer { l in
            rb.withUnsafeMutableBufferPointer { r in
                b.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: l.count)
            }
        }
        XCTAssertEqual(la, lb)
        XCTAssertEqual(ra, rb)
    }

    func testMicrophoneSettingsPersistAndOlderDAWStateDecodes() throws {
        var state = DAWState()
        state.virtualMicrophoneSettings = StudioVirtualMicrophoneSettings(
            perspective: .audience, stereoWidth: 1.25
        )
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(DAWState.self, from: data)
        XCTAssertEqual(restored.virtualMicrophoneSettings, state.virtualMicrophoneSettings)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data)
                                   as? [String: Any])
        legacy.removeValue(forKey: "virtualMicrophoneSettings")
        let older = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(DAWState.self, from: older)
                        .virtualMicrophoneSettings)
        XCTAssertEqual(StudioVirtualMicrophoneSettings().perspective, .conductor)
    }

    func testInvalidMicrophoneParametersAreClamped() {
        let processor = NativeStageEarlyReflectionProcessor(sampleRate: 24_000)
        processor.update(roomIndex: 999, pan: 0.1, zone: 5,
                         microphonePerspective: 200, microphoneWidth: .nan)
        XCTAssertEqual(processor.microphonePerspectiveIndex, 2)
        XCTAssertEqual(processor.microphoneStereoWidth, 1)
        XCTAssertEqual(StudioVirtualMicrophoneSettings(stereoWidth: 3).safeWidth, 1.5)
    }
}

final class NativeRoomImpulseAnalyzerTests: XCTestCase {
    func testNarrowerOctaveAnalysisRejectsDistantLowFrequencyLeakage() {
        let sampleRate = 48_000.0
        let count = Int(sampleRate)
        let unwanted = (0..<count).map { index -> Double in
            sin(2 * Double.pi * 125 * Double(index) / sampleRate)
        }
        let legacy = NativeRoomImpulseAnalyzer.octaveApproximate(
            unwanted, sampleRate: sampleRate, centerHz: 1_000,
            filter: .legacyWideBand)
        let improved = NativeRoomImpulseAnalyzer.octaveApproximate(
            unwanted, sampleRate: sampleRate, centerHz: 1_000,
            filter: .cascadedButterworth)
        // Ignore filter startup transient: compare steady-state squared energy.
        func energy(_ x: [Double]) -> Double {
            x.dropFirst(24_000).reduce(0) { $0 + $1 * $1 }
        }
        XCTAssertLessThan(energy(improved), energy(legacy) * 0.3)
        XCTAssertTrue(improved.allSatisfy(\.isFinite))

        let wanted = (0..<count).map { index -> Double in
            sin(2 * Double.pi * 1_000 * Double(index) / sampleRate)
        }
        let filteredWanted = NativeRoomImpulseAnalyzer.octaveApproximate(
            wanted, sampleRate: sampleRate, centerHz: 1_000,
            filter: .cascadedButterworth)
        XCTAssertGreaterThan(energy(filteredWanted), energy(wanted) * 0.4)
    }

    func testKnownExponentialDecayT20IsApproximatelyCorrect() {
        let sampleRate = 24_000.0
        let n = Int(sampleRate * 3.5)
        let targetRT60 = 1.7
        let signal: [Float] = (0..<n).map { i in
            let t = Double(i) / sampleRate
            let envelope = exp(-3 * log(10) * t / targetRT60)
            return Float(envelope * sin(2 * Double.pi * 500 * t))
        }
        let result = NativeRoomImpulseAnalyzer.analyze(
            left: signal, right: signal, sampleRate: sampleRate, roomID: "synthetic"
        )
        let measured = result.bands.first(where: { $0.bandCenterHz == 500 })?.t20Seconds
        XCTAssertNotNil(measured)
        XCTAssertEqual(measured ?? 0, targetRT60, accuracy: 0.2)
    }

    func testStereoAntiPhaseImpulseStillReportsValidDecay() {
        // A mono (L+R)/2 analysis would cancel this entire signal.
        let rate = 24_000.0
        let frames = Int(rate * 3)
        var left = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let t = Double(n) / rate
            left[n] = Float(exp(-3 * log(10) * t / 1.8) *
                            sin(2 * Double.pi * 1_000 * t))
        }
        let right = left.map { -$0 }
        let result = NativeRoomImpulseAnalyzer.analyze(
            left: left, right: right, sampleRate: rate, roomID: "anti-phase")
        XCTAssertEqual(result.bands.count, 6)
        XCTAssertEqual(result.bands[3].t20Seconds ?? 0, 1.8, accuracy: 0.2)
    }

    func testFrequencyAboveNyquistIsNotReportedAsMeasured() {
        let rate = 8_000.0
        let left = [Float](repeating: 0, count: 8_000)
        let measured = NativeRoomImpulseAnalyzer.analyze(
            left: left, right: left, sampleRate: rate, roomID: "silent")
        XCTAssertEqual(measured.bands.count, 6)
        XCTAssertNil(measured.bands.last?.t20Seconds)
    }

    func testAllFourRoomsHaveFiniteOfflineCalibrationReports() throws {
        let profiles = StudioRoomAcousticProfile.starterProfiles
        XCTAssertEqual(profiles.count, 4)
        for room in profiles {
            let report = NativeRoomImpulseAnalyzer.measure(room: room,
                                                            sampleRate: 24_000,
                                                            seconds: 3.5)
            XCTAssertEqual(report.roomID, room.id)
            XCTAssertEqual(report.bands.count, 6)
            XCTAssertEqual(report.bands.map(\.bandCenterHz),
                           [125, 250, 500, 1_000, 2_000, 4_000])
            for band in report.bands {
                XCTAssertTrue(band.edtSeconds == nil || band.edtSeconds!.isFinite)
                XCTAssertTrue(band.t20Seconds == nil || band.t20Seconds!.isFinite)
                XCTAssertTrue(band.t30Seconds == nil || band.t30Seconds!.isFinite)
            }
            let data = try JSONEncoder().encode(report)
            XCTAssertFalse(data.isEmpty)
        }
    }
}
