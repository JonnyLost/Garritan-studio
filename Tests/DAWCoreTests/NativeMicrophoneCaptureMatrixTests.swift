import XCTest
@testable import DAWCore

final class NativeMicrophoneCaptureMatrixTests: XCTestCase {
    private let rate = 48_000.0

    private func render(
        _ matrix: NativeMicrophoneCaptureMatrix,
        sourceAudio: [[Float]], chunkSize: Int
    ) -> [[Float]] {
        let length = sourceAudio[0].count
        let inputs = sourceAudio.map { audio -> UnsafeMutablePointer<Float> in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: length)
            ptr.initialize(from: audio, count: length)
            return ptr
        }
        let outputPointers = (0..<matrix.microphoneCount).map { _ -> UnsafeMutablePointer<Float> in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: length)
            ptr.initialize(repeating: 0, count: length)
            return ptr
        }
        defer {
            for pointer in inputs {
                pointer.deinitialize(count: length)
                pointer.deallocate()
            }
            for pointer in outputPointers {
                pointer.deinitialize(count: length)
                pointer.deallocate()
            }
        }
        var offset = 0
        while offset < length {
            let count = min(chunkSize, length - offset)
            let sources = inputs.map { pointer in
                NativeMicrophoneCaptureMatrix.Source(
                    left: UnsafePointer(pointer.advanced(by: offset)),
                    right: UnsafePointer(pointer.advanced(by: offset))
                )
            }
            let outputs = outputPointers.map { $0.advanced(by: offset) }
            XCTAssertTrue(matrix.render(sources: sources, outputs: outputs,
                                        frameCount: count))
            offset += count
        }
        return outputPointers.map { Array(UnsafeBufferPointer(start: $0, count: length)) }
    }

    func testSharedHistoryScalesWithSourcesNotMicrophonePairs() throws {
        let matrix = try XCTUnwrap(NativeMicrophoneCaptureMatrix(
            sampleRate: rate, sources: 64, microphones: 4
        ))
        let one = try XCTUnwrap(NativeMicrophoneCaptureMatrix(
            sampleRate: rate, sources: 64, microphones: 1
        ))
        XCTAssertEqual(matrix.historySampleCount, one.historySampleCount)
        XCTAssertEqual(matrix.sourceCount, 64)
        XCTAssertEqual(matrix.microphoneCount, 4)
        XCTAssertNil(NativeMicrophoneCaptureMatrix(
            sampleRate: rate, sources: 65, microphones: 4
        ))
    }

    func testEverySourceSpillsIntoEveryMicrophoneWithOwnDelay() throws {
        let matrix = try XCTUnwrap(NativeMicrophoneCaptureMatrix(
            sampleRate: rate, sources: 2, microphones: 2
        ))
        XCTAssertTrue(matrix.setPath(source: 0, microphone: 0,
                                     gain: 1, delayMilliseconds: 10,
                                     lowPassAlpha: 1))
        XCTAssertTrue(matrix.setPath(source: 1, microphone: 0,
                                     gain: 0.5, delayMilliseconds: 20,
                                     lowPassAlpha: 1))
        XCTAssertTrue(matrix.setPath(source: 0, microphone: 1,
                                     gain: -0.5, delayMilliseconds: 10,
                                     lowPassAlpha: 1))
        XCTAssertTrue(matrix.setPath(source: 1, microphone: 1,
                                     gain: 1, delayMilliseconds: 20,
                                     lowPassAlpha: 1))
        var first = [Float](repeating: 0, count: 2_000)
        var second = first
        first[0] = 1
        second[0] = 1
        let outputs = render(matrix, sourceAudio: [first, second], chunkSize: 73)
        XCTAssertEqual(outputs[0][480], 1, accuracy: 0.0001)
        XCTAssertEqual(outputs[0][960], 0.5, accuracy: 0.0001)
        XCTAssertEqual(outputs[1][480], -0.5, accuracy: 0.0001)
        XCTAssertEqual(outputs[1][960], 1, accuracy: 0.0001)
        XCTAssertTrue(outputs[0][0..<480].allSatisfy { $0 == 0 })
    }

    func testIndependentBlockSizesAndFractionalDelay() throws {
        func run(chunk: Int) throws -> [[Float]] {
            let matrix = try XCTUnwrap(NativeMicrophoneCaptureMatrix(
                sampleRate: rate, sources: 1, microphones: 2
            ))
            let halfFrameMs = Float(500 / rate)
            _ = matrix.setPath(source: 0, microphone: 0,
                               gain: -1, delayMilliseconds: halfFrameMs,
                               lowPassAlpha: 1)
            _ = matrix.setPath(source: 0, microphone: 1,
                               gain: 0.25, delayMilliseconds: 0,
                               lowPassAlpha: 0.5)
            var audio = [Float](repeating: 0, count: 1_000)
            audio[0] = 1
            return render(matrix, sourceAudio: [audio], chunkSize: chunk)
        }
        let a = try run(chunk: 1_000)
        let b = try run(chunk: 37)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a[0][0], -0.5, accuracy: 0.0001)
        XCTAssertEqual(a[0][1], -0.5, accuracy: 0.0001)
    }

    func testUnsafeCardinalityRejectedAndNonfiniteParametersClamped() throws {
        let matrix = try XCTUnwrap(NativeMicrophoneCaptureMatrix(
            sampleRate: rate, sources: 1, microphones: 1
        ))
        XCTAssertFalse(matrix.setPath(source: 2, microphone: 0,
                                      gain: 1, delayMilliseconds: 0,
                                      lowPassAlpha: 1))
        XCTAssertTrue(matrix.setPath(source: 0, microphone: 0,
                                     gain: .nan, delayMilliseconds: .infinity,
                                     lowPassAlpha: .nan))
        let outputs = render(matrix, sourceAudio: [
            Array(repeating: 1, count: 256)
        ], chunkSize: 64)
        XCTAssertTrue(outputs[0].allSatisfy { $0 == 0 })
        XCTAssertFalse(matrix.render(sources: [], outputs: [], frameCount: 32))
    }
}
