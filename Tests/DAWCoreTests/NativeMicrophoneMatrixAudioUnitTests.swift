import XCTest
import AVFoundation
@testable import DAWCore

@MainActor
final class NativeMicrophoneMatrixAudioUnitTests: XCTestCase {
    func testFourOutputBussesExposeIndependentCapsuleParameters() throws {
        NativeMicrophoneMatrixAudioUnit.registerIfNeeded()
        let capture = AVAudioUnitEffect(
            audioComponentDescription: NativeMicrophoneMatrixAudioUnit.componentDescription
        )
        XCTAssertEqual(capture.auAudioUnit.inputBusses.count, 1)
        XCTAssertEqual(capture.auAudioUnit.outputBusses.count, 4)

        let tree = try XCTUnwrap(capture.auAudioUnit.parameterTree)
        for i in 0..<4 {
            XCTAssertNotNil(tree.parameter(
                withAddress: NativeMicrophoneMatrixAudioUnit.gainAddress(i)
            ))
            XCTAssertNotNil(tree.parameter(
                withAddress: NativeMicrophoneMatrixAudioUnit.delayAddress(i)
            ))
            XCTAssertNotNil(tree.parameter(
                withAddress: NativeMicrophoneMatrixAudioUnit.filterAddress(i)
            ))
        }
    }

    /// macOS Audio Unit host acceptance test: detect unsupported multi-bus
    /// graph connections in CI before offering the backend as default.
    func testFourIndependentOutputsConnectAndRenderInManualEngine() throws {
        NativeMicrophoneMatrixAudioUnit.registerIfNeeded()
        let audioFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        )
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let capture = AVAudioUnitEffect(
            audioComponentDescription: NativeMicrophoneMatrixAudioUnit.componentDescription
        )
        engine.attach(player)
        engine.attach(capture)
        engine.connect(player, to: capture, format: audioFormat)

        let mixers = (0..<4).map { _ in AVAudioMixerNode() }
        for (index, mixer) in mixers.enumerated() {
            engine.attach(mixer)
            engine.connect(
                capture, to: mixer, fromBus: AVAudioNodeBus(index),
                toBus: mixer.nextAvailableInputBus, format: audioFormat
            )
            engine.connect(mixer, to: engine.mainMixerNode, format: audioFormat)
            mixer.outputVolume = index == 0 ? 1 : 0
        }

        // Only capsule 0 is audible in this graph smoke test; other outputs
        // are still connected and must not advance the matrix clock twice.
        capture.auAudioUnit.parameterTree?.parameter(
            withAddress: NativeMicrophoneMatrixAudioUnit.gainAddress(0)
        )?.value = 1
        capture.auAudioUnit.parameterTree?.parameter(
            withAddress: NativeMicrophoneMatrixAudioUnit.filterAddress(0)
        )?.value = 1
        try engine.enableManualRenderingMode(
            .offline, format: audioFormat, maximumFrameCount: 512
        )
        try engine.start()
        defer { engine.stop() }

        let input = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: audioFormat, frameCapacity: 512
        ))
        input.frameLength = 512
        let samples = try XCTUnwrap(input.floatChannelData)
        for channel in 0..<2 {
            for index in 0..<512 { samples[channel][index] = 0 }
            samples[channel][0] = 0.5
        }
        player.scheduleBuffer(input, at: nil, options: [])
        player.play()

        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 512
        ))
        let result = try engine.renderOffline(512, to: output)
        XCTAssertEqual(result, .success)
        let channels = try XCTUnwrap(output.floatChannelData)
        XCTAssertTrue((0..<512).allSatisfy { index in
            channels[0][index].isFinite && channels[1][index].isFinite
        })
    }
}
