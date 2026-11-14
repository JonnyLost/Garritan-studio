import XCTest
import AudioToolbox
import DAWRealtime
@testable import DAWCore

final class StudioAudioTransitionTests: XCTestCase {
    func testCrossfadeIsContinuousAcrossBuffersAndBounded() {
        let oldL = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let oldR = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let newL = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let newR = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer {
            oldL.deallocate(); oldR.deallocate()
            newL.deallocate(); newR.deallocate()
        }
        oldL.initialize(repeating: 1, count: 64)
        oldR.initialize(repeating: 0.5, count: 64)
        newL.initialize(repeating: -1, count: 64)
        newR.initialize(repeating: -0.5, count: 64)

        StudioInstrumentCrossfade.blend(
            oldLeft: UnsafePointer(oldL), oldRight: UnsafePointer(oldR),
            newLeft: newL, newRight: newR,
            frames: 64, startFrame: 0, totalFrames: 128
        )
        XCTAssertEqual(newL[0], 1, accuracy: 0.0001)
        XCTAssertEqual(newR[0], 0.5, accuracy: 0.0001)
        let endFirst = newL[63]

        for i in 0..<64 {
            newL[i] = -1
            newR[i] = -0.5
        }
        StudioInstrumentCrossfade.blend(
            oldLeft: UnsafePointer(oldL), oldRight: UnsafePointer(oldR),
            newLeft: newL, newRight: newR,
            frames: 64, startFrame: 64, totalFrames: 128
        )
        XCTAssertLessThan(abs(newL[0] - endFirst), 0.02)
        XCTAssertEqual(newL[63], -0.984375, accuracy: 0.0001)
        XCTAssertEqual(newR[63], -0.4921875, accuracy: 0.0001)
        XCTAssertEqual(newL[0], 0, accuracy: 0.0001)
    }

    func testAtomicTransitionProgressSaturatesAndCanBeCanceled() {
        guard let progress = daw_transition_create(128) else {
            XCTFail("Cannot allocate fade progress")
            return
        }
        defer { daw_transition_destroy(progress) }
        XCTAssertEqual(daw_transition_total(progress), 128)
        XCTAssertEqual(daw_transition_completed(progress), 0)
        XCTAssertEqual(daw_transition_advance(progress, 64), 0)
        XCTAssertEqual(daw_transition_completed(progress), 64)
        XCTAssertEqual(daw_transition_advance(progress, 200), 64)
        XCTAssertEqual(daw_transition_completed(progress), 128)
        XCTAssertEqual(daw_transition_advance(progress, 1000), 128)
        daw_transition_force_complete(progress)
        XCTAssertEqual(daw_transition_completed(progress), 128)
    }

    func testEffectInputCopiesStereoUpstreamAtSliceOffset() {
        struct StereoBufferList {
            var mNumberBuffers: UInt32 = 2
            var left = AudioBuffer()
            var right = AudioBuffer()
        }

        let context = StudioEffectInputContext()
        let sourceL = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let sourceR = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let outputL = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let outputR = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer {
            sourceL.deallocate(); sourceR.deallocate()
            outputL.deallocate(); outputR.deallocate()
        }
        sourceL.initialize(repeating: 0, count: 8)
        sourceR.initialize(repeating: 0, count: 8)
        for i in 0..<8 {
            sourceL[i] = Float(i) / 8
            sourceR[i] = -Float(i) / 8
        }
        outputL.initialize(repeating: 0, count: 4)
        outputR.initialize(repeating: 0, count: 4)
        context.setSource(
            left: UnsafePointer(sourceL), right: UnsafePointer(sourceR),
            sampleTime: 100, frames: 8
        )
        var stamp = AudioTimeStamp()
        stamp.mFlags = .sampleTimeValid
        stamp.mSampleTime = 102
        var io = StereoBufferList()
        io.left = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: outputL)
        io.right = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: outputR)
        let status = withUnsafePointer(to: &stamp) { stampPtr in
            withUnsafeMutablePointer(to: &io) { ptr in
                ptr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { abl in
                    context.supply(timeStamp: stampPtr, frames: 4, output: abl)
                }
            }
        }
        XCTAssertEqual(status, noErr)
        for i in 0..<4 {
            XCTAssertEqual(outputL[i], Float(i + 2) / 8, accuracy: 0.00001)
            XCTAssertEqual(outputR[i], -Float(i + 2) / 8, accuracy: 0.00001)
        }
    }

    func testEffectInputReturnsSilenceWhenNoSourceIsReady() {
        struct StereoBufferList {
            var mNumberBuffers: UInt32 = 2
            var left = AudioBuffer()
            var right = AudioBuffer()
        }
        let context = StudioEffectInputContext()
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let outR = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { outL.deallocate(); outR.deallocate() }
        outL.initialize(repeating: 1, count: 4)
        outR.initialize(repeating: 1, count: 4)
        var stamp = AudioTimeStamp()
        var io = StereoBufferList()
        io.left = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: outL)
        io.right = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: outR)
        let status = withUnsafePointer(to: &stamp) { stampPtr in
            withUnsafeMutablePointer(to: &io) { ptr in
                ptr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) {
                    context.supply(timeStamp: stampPtr, frames: 4, output: $0)
                }
            }
        }
        XCTAssertEqual(status, noErr)
        for i in 0..<4 {
            XCTAssertEqual(outL[i], 0)
            XCTAssertEqual(outR[i], 0)
        }
    }
    /// This exercises Apple's actual native effect renderer with a nonzero
    /// signal, not just our standalone input copy routine. No output device
    /// or external third-party plug-in is needed on the macOS CI runner.
    func testAppleEffectReceivesUpstreamPCM() throws {
        struct StereoBufferList {
            var mNumberBuffers: UInt32 = 2
            var left = AudioBuffer()
            var right = AudioBuffer()
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &description) != nil else {
            throw XCTSkip("Apple NBandEQ Audio Unit not installed on this runner")
        }
        let graph = RenderGraph(sampleRate: 44_100, bufferSize: 512)
        let prepared = try graph.prepareEffect(description)
        let effect = try XCTUnwrap(prepared.unit)
        let frameCount = 512
        let dryL = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let dryR = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputL = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputR = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            dryL.deallocate(); dryR.deallocate()
            outputL.deallocate(); outputR.deallocate()
        }
        dryL.initialize(repeating: 0, count: frameCount)
        dryR.initialize(repeating: 0, count: frameCount)
        outputL.initialize(repeating: 0, count: frameCount)
        outputR.initialize(repeating: 0, count: frameCount)

        var energy: Float = 0
        for chunk in 0..<4 {
            for i in 0..<frameCount {
                let value = Float(sin(Double(chunk * frameCount + i) * 0.1)) * 0.2
                dryL[i] = value
                dryR[i] = value
                outputL[i] = 0
                outputR[i] = 0
            }
            let startSample = Float64(chunk * frameCount)
            prepared.input.setSource(
                left: UnsafePointer(dryL), right: UnsafePointer(dryR),
                sampleTime: startSample, frames: UInt32(frameCount)
            )
            var stamp = AudioTimeStamp()
            stamp.mFlags = .sampleTimeValid
            stamp.mSampleTime = startSample
            var flags = AudioUnitRenderActionFlags()
            var buffers = StereoBufferList()
            buffers.left = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 2048, mData: outputL
            )
            buffers.right = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 2048, mData: outputR
            )
            let status: OSStatus = withUnsafeMutablePointer(to: &buffers) { ptr in
                ptr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { abl in
                    AudioUnitRender(effect, &flags, &stamp, 0, UInt32(frameCount), abl)
                }
            }
            XCTAssertEqual(status, noErr, "Real Apple effect input render failed")
            for i in 0..<frameCount { energy += abs(outputL[i]) + abs(outputR[i]) }
        }
        XCTAssertGreaterThan(energy, 1, "Apple effect did not receive or output input PCM")
    }

}
