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

final class NativeRoomImpulseAnalyzerTests: XCTestCase {
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
