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
    func testPCMPagesPublishStereoDataAndCountMissingFrames() throws {
        let cache = try XCTUnwrap(daw_pcm_page_cache_create(4, 2))
        defer { daw_pcm_page_cache_destroy(cache) }
        var left = [Float](repeating: 0, count: 6)
        var right = left
        XCTAssertEqual(daw_pcm_page_cache_mix(
            cache, 0, 4, &left, &right, 1
        ), 0)
        XCTAssertEqual(daw_pcm_page_cache_underrun_frames(cache), 4)

        var requested: UInt64 = 999
        XCTAssertTrue(daw_pcm_page_cache_requested_page(cache, &requested))
        XCTAssertEqual(requested, 0)
        let first: [Float] = [1, 10, 2, 20, 3, 30, 4, 40]
        XCTAssertTrue(first.withUnsafeBufferPointer {
            daw_pcm_page_cache_supply(cache, 0, $0.baseAddress, 4)
        })
        XCTAssertTrue(daw_pcm_page_cache_contains(cache, 0))
        XCTAssertEqual(daw_pcm_page_cache_mix(cache, 0, 4, &left, &right, 0.5), 4)
        XCTAssertEqual(Array(left.prefix(4)), [0.5, 1, 1.5, 2])
        XCTAssertEqual(Array(right.prefix(4)), [5, 10, 15, 20])

        let second: [Float] = [5, 50, 6, 60, 7, 70, 8, 80]
        XCTAssertTrue(second.withUnsafeBufferPointer {
            daw_pcm_page_cache_supply(cache, 1, $0.baseAddress, 4)
        })
        XCTAssertEqual(daw_pcm_page_cache_mix(cache, 2, 4, &left, &right, 1), 4)
        XCTAssertEqual(Array(left.prefix(4)), [3.5, 5, 6.5, 8])
        XCTAssertEqual(Array(right.prefix(4)), [35, 50, 65, 80])
        XCTAssertEqual(daw_pcm_page_cache_underrun_frames(cache), 4)

        // Page zero and page two alias the same bounded slot. A seek must
        // never return stale page-zero samples for page two.
        XCTAssertFalse(daw_pcm_page_cache_contains(cache, 2))
        XCTAssertTrue(first.withUnsafeBufferPointer {
            daw_pcm_page_cache_supply(cache, 2, $0.baseAddress, 4)
        })
        XCTAssertFalse(daw_pcm_page_cache_contains(cache, 0))
        XCTAssertEqual(daw_pcm_page_cache_mix(cache, 0, 4, &left, &right, 1), 0)
        XCTAssertEqual(daw_pcm_page_cache_underrun_frames(cache), 8)
    }

    func testPCMPageCacheRejectsUnboundedAllocations() {
        XCTAssertNil(daw_pcm_page_cache_create(0, 4))
        XCTAssertNil(daw_pcm_page_cache_create(4096, 0))
        XCTAssertNil(daw_pcm_page_cache_create(4096, 17))
    }
}
