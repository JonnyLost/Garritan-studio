import XCTest
import AVFoundation
@testable import DAWCore

/// Non-destructive host-level diagnosis. Does not alter production routing.
/// Compare a standalone capsule against the rack fanout that goes silent
/// in VRackMicrophoneRoutingTests. Both backends must produce real PCM.
@MainActor
final class NativeMicrophoneAuditionGraphDiagnosticsTests: XCTestCase {
    private func checkAudible(shared: Bool, rackFanout: Bool) throws {
        if shared {
            NativeMicrophoneMatrixAudioUnit.registerIfNeeded()
        } else {
            NativeMicrophoneSpillAudioUnit.registerIfNeeded()
        }
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let player = AVAudioPlayerNode()
        let capture = AVAudioUnitEffect(audioComponentDescription: shared
            ? NativeMicrophoneMatrixAudioUnit.componentDescription
            : NativeMicrophoneSpillAudioUnit.componentDescription)
        engine.attach(player)
        engine.attach(capture)

        if rackFanout {
            let rack = AVAudioMixerNode()
            let dry = AVAudioMixerNode()
            let mic = AVAudioMixerNode()
            let micMaster = AVAudioMixerNode()
            for node in [rack, dry, mic, micMaster] { engine.attach(node) }
            engine.connect(player, to: rack, format: format)
            engine.connect(dry, to: engine.mainMixerNode, format: format)
            engine.connect(capture, to: mic,
                           fromBus: 0, toBus: mic.nextAvailableInputBus,
                           format: format)
            engine.connect(mic, to: micMaster, format: format)
            engine.connect(micMaster, to: engine.mainMixerNode, format: format)
            engine.connect(rack, to: [
                AVAudioConnectionPoint(node: dry, bus: 0),
                AVAudioConnectionPoint(node: capture, bus: 0)
            ], fromBus: 0, format: format)
            dry.outputVolume = 0
            mic.outputVolume = 1
            micMaster.outputVolume = 1
        } else {
            engine.connect(player, to: capture, format: format)
            engine.connect(capture, to: engine.mainMixerNode,
                           fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus,
                           format: format)
        }

        let gainAddress = shared
            ? NativeMicrophoneMatrixAudioUnit.gainAddress(0)
            : NativeMicrophoneSpillAudioUnit.signedGainAddress
        let delayAddress = shared
            ? NativeMicrophoneMatrixAudioUnit.delayAddress(0)
            : NativeMicrophoneSpillAudioUnit.delayMillisecondsAddress
        let filterAddress = shared
            ? NativeMicrophoneMatrixAudioUnit.filterAddress(0)
            : NativeMicrophoneSpillAudioUnit.lowPassAlphaAddress
        let params = try XCTUnwrap(capture.auAudioUnit.parameterTree)
        params.parameter(withAddress: gainAddress)?.value = 1
        params.parameter(withAddress: delayAddress)?.value = 0
        params.parameter(withAddress: filterAddress)?.value = 1
        try engine.enableManualRenderingMode(.offline,
                                              format: format,
                                              maximumFrameCount: 512)
        try engine.start()
        defer { engine.stop() }

        let sample = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                  frameCapacity: 512))
        sample.frameLength = 512
        let channels = try XCTUnwrap(sample.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<512 {
                channels[channel][frame] = 0.25
            }
        }
        player.scheduleBuffer(sample, at: nil, options: [.loops])
        player.play()
        defer { player.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 512
        ))
        var peak: Float = 0
        for block in 0..<72 {
            let result = try engine.renderOffline(512, to: output)
            XCTAssertEqual(result, .success)
            let samples = try XCTUnwrap(output.floatChannelData)
            if block >= 40 {
                for frame in 0..<512 {
                    peak = max(peak, abs(samples[0][frame]), abs(samples[1][frame]))
                }
            }
        }
        XCTAssertGreaterThan(peak, 0.01,
            "Mic AU silent: shared=\(shared), rackFanout=\(rackFanout)")
    }

    func testIsolatedCapsulesProduceAudio() throws {
        for shared in [false, true] {
            try checkAudible(shared: shared, rackFanout: false)
        }
    }

    func testFanoutCapsulesProduceAudioWithoutDryMonitor() throws {
        for shared in [false, true] {
            try checkAudible(shared: shared, rackFanout: true)
        }
    }
}
