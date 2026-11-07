import XCTest
@testable import DAWCore

final class StereoPositionProcessorTests: XCTestCase {
    private func render(_ processor: inout StereoPositionProcessor, _ l: [Float], _ r: [Float]) -> ([Float], [Float]) {
        var left = l
        var right = r
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                processor.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        return (left, right)
    }

    func testCenterIsExactStereoPassthrough() {
        var dsp = StereoPositionProcessor()
        let (l, r) = render(&dsp, [0.7, -0.3, 0.2], [-0.2, 0.8, 0.1])
        XCTAssertEqual(l, [0.7, -0.3, 0.2])
        XCTAssertEqual(r, [-0.2, 0.8, 0.1])
    }

    func testHardLeftFoldsBothChannelsWithoutDroppingRightInput() {
        var dsp = StereoPositionProcessor(pan: -1)
        let (l, r) = render(&dsp, [0.8, 0], [0, 0.6])
        XCTAssertEqual(l[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(l[1], 0.3, accuracy: 0.00001)
        XCTAssertEqual(r, [0, 0])
    }

    func testHardRightFoldsBothChannels() {
        var dsp = StereoPositionProcessor(pan: 1)
        let (l, r) = render(&dsp, [0.8], [0.2])
        XCTAssertEqual(l[0], 0, accuracy: 0.00001)
        XCTAssertEqual(r[0], 0.5, accuracy: 0.00001)
    }

    func testPanTransitionRampsAcrossBuffer() {
        var dsp = StereoPositionProcessor()
        dsp.setPan(1)
        let (l, r) = render(&dsp, [1, 1, 1, 1], [0, 0, 0, 0])
        XCTAssertEqual(l[0], 0.75, accuracy: 0.00001)
        XCTAssertEqual(l[3], 0, accuracy: 0.00001)
        XCTAssertEqual(r[0], 0.125, accuracy: 0.00001)
        XCTAssertEqual(r[3], 0.5, accuracy: 0.00001)
    }

    func testInvalidPanResetsToCenter() {
        var dsp = StereoPositionProcessor(pan: 0.5)
        dsp.reset(pan: .nan)
        XCTAssertEqual(dsp.pan, 0)
    }

    func testEmptyBufferDoesNotChangeState() {
        var dsp = StereoPositionProcessor()
        dsp.setPan(-1)
        var l: Float = 1
        var r: Float = 0
        dsp.process(left: &l, right: &r, frameCount: 0)
        XCTAssertEqual(l, 1)
        XCTAssertEqual(r, 0)
    }
}
