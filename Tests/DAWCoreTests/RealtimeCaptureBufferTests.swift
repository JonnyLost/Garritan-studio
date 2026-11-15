import XCTest
import DAWRealtime

final class RealtimeCaptureBufferTests: XCTestCase {
    func testStereoRingWraparoundPreservesOrder() throws {
        let ring = try XCTUnwrap(daw_audio_ring_create(8))
        defer { daw_audio_ring_destroy(ring) }
        let firstLeft: [Float] = [1, 2, 3, 4, 5, 6]
        let firstRight: [Float] = [-1, -2, -3, -4, -5, -6]
        firstLeft.withUnsafeBufferPointer { left in
            firstRight.withUnsafeBufferPointer { right in
                XCTAssertTrue(daw_audio_ring_push(
                    ring, left.baseAddress, right.baseAddress, 2, 6, false
                ))
            }
        }
        var result = [Float](repeating: 0, count: 12)
        result.withUnsafeMutableBufferPointer { output in
            XCTAssertEqual(daw_audio_ring_pop(ring, output.baseAddress, 4), 4)
        }
        XCTAssertEqual(Array(result.prefix(8)), [1, -1, 2, -2, 3, -3, 4, -4])

        let secondLeft: [Float] = [7, 8, 9, 10]
        let secondRight: [Float] = [-7, -8, -9, -10]
        secondLeft.withUnsafeBufferPointer { left in
            secondRight.withUnsafeBufferPointer { right in
                XCTAssertTrue(daw_audio_ring_push(
                    ring, left.baseAddress, right.baseAddress, 2, 4, false
                ))
            }
        }
        result.withUnsafeMutableBufferPointer { output in
            XCTAssertEqual(daw_audio_ring_pop(ring, output.baseAddress, 6), 6)
        }
        XCTAssertEqual(result, [5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10])
        XCTAssertEqual(daw_audio_ring_accepted_frames(ring), 10)
        XCTAssertEqual(daw_audio_ring_dropped_frames(ring), 0)
    }

    func testMonoInputDuplicatesChannelsAndOverrunIsReported() throws {
        let ring = try XCTUnwrap(daw_audio_ring_create(4))
        defer { daw_audio_ring_destroy(ring) }
        let mono: [Float] = [0.25, 0.5, -0.5, 0.75]
        mono.withUnsafeBufferPointer { input in
            XCTAssertTrue(daw_audio_ring_push(
                ring, input.baseAddress, input.baseAddress, 1, 4, false
            ))
            XCTAssertFalse(daw_audio_ring_push(
                ring, input.baseAddress, input.baseAddress, 1, 1, false
            ))
        }
        XCTAssertEqual(daw_audio_ring_dropped_frames(ring), 1)
        var result = [Float](repeating: 0, count: 8)
        result.withUnsafeMutableBufferPointer { output in
            XCTAssertEqual(daw_audio_ring_pop(ring, output.baseAddress, 4), 4)
        }
        XCTAssertEqual(result, [0.25, 0.25, 0.5, 0.5, -0.5, -0.5, 0.75, 0.75])
        XCTAssertEqual(daw_audio_ring_take_peak(ring), 0.75, accuracy: 0.001)
        XCTAssertEqual(daw_audio_ring_take_peak(ring), 0, accuracy: 0.001)
    }

    func testStereoMeterSeparatesChannelsAndAtomicPositionHandoff() throws {
        let meter = try XCTUnwrap(daw_audio_stereo_meter_create())
        defer { daw_audio_stereo_meter_destroy(meter) }
        let left: [Float] = [0.1, 0.6, -0.2]
        let right: [Float] = [-0.9, 0.3, 0.2]
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                daw_audio_stereo_meter_measure(
                    meter, l.baseAddress, r.baseAddress, 2, 3, false
                )
            }
        }
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        daw_audio_stereo_meter_take(meter, &leftPeak, &rightPeak)
        XCTAssertEqual(leftPeak, 0.6, accuracy: 0.00001)
        XCTAssertEqual(rightPeak, 0.9, accuracy: 0.00001)
        daw_audio_stereo_meter_take(meter, &leftPeak, &rightPeak)
        XCTAssertEqual(leftPeak, 0, accuracy: 0.00001)
        XCTAssertEqual(rightPeak, 0, accuracy: 0.00001)

        let position = try XCTUnwrap(daw_sample_position_create())
        defer { daw_sample_position_destroy(position) }
        XCTAssertEqual(daw_sample_position_load(position), 0)
        daw_sample_position_publish(position, 12_345)
        XCTAssertEqual(daw_sample_position_load(position), 12_345)
        daw_sample_position_publish(position, 678)
        XCTAssertEqual(daw_sample_position_load(position), 678)
    }

    func testInterleavedStereoInputAndAtomicMeterReset() throws {
        let ring = try XCTUnwrap(daw_audio_ring_create(4))
        defer { daw_audio_ring_destroy(ring) }
        let stereo: [Float] = [0.1, -0.2, 0.3, -0.8, 0.9, -0.1]
        stereo.withUnsafeBufferPointer { input in
            XCTAssertTrue(daw_audio_ring_push(
                ring, input.baseAddress, input.baseAddress, 2, 3, true
            ))
        }
        var result = [Float](repeating: 0, count: 6)
        result.withUnsafeMutableBufferPointer { output in
            XCTAssertEqual(daw_audio_ring_pop(ring, output.baseAddress, 3), 3)
        }
        for index in result.indices {
            XCTAssertEqual(result[index], stereo[index], accuracy: 0.00001)
        }
        XCTAssertEqual(daw_audio_ring_take_peak(ring), 0.9, accuracy: 0.00001)

        let meter = try XCTUnwrap(daw_audio_peak_meter_create())
        defer { daw_audio_peak_meter_destroy(meter) }
        stereo.withUnsafeBufferPointer { input in
            daw_audio_peak_meter_measure(meter, input.baseAddress, input.baseAddress, 2, 3, true)
        }
        XCTAssertEqual(daw_audio_peak_meter_take(meter), 0.9, accuracy: 0.00001)
        XCTAssertEqual(daw_audio_peak_meter_take(meter), 0, accuracy: 0.00001)
    }
}
