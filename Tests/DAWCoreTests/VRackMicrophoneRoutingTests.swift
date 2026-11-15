import XCTest
import AVFoundation
@testable import DAWCore

/// Integration tests for the V-Rack's real AVAudioEngine signal graph,
/// not merely isolated source/microphone geometry calculations.
@MainActor
final class VRackMicrophoneRoutingTests: XCTestCase {
    private func makeInput(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let input = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 512
        ))
        input.frameLength = 512
        let samples = try XCTUnwrap(input.floatChannelData)
        for channel in 0..<2 {
            for sample in 0..<512 { samples[channel][sample] = 0.25 }
        }
        return input
    }

    private func renderPeak(_ engine: AVAudioEngine,
                            count: Int = 72, settleBlocks: Int = 40) throws -> Float {
        // AVAudioEngine can retain buffers queued across upstream mixer
        // fanouts and AU/mixer gain changes. Measure only the settled
        // signal, not stale buffers following a monitoring transition.
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 512
        ))
        var peak: Float = 0
        for block in 0..<count {
            let status = try engine.renderOffline(512, to: output)
            XCTAssertEqual(status, .success)
            let channels = try XCTUnwrap(output.floatChannelData)
            for sample in 0..<512 {
                XCTAssertTrue(channels[0][sample].isFinite)
                XCTAssertTrue(channels[1][sample].isFinite)
                if block >= settleBlocks {
                    peak = max(peak, abs(channels[0][sample]),
                               abs(channels[1][sample]))
                }
            }
        }
        return peak
    }

    func testVRackDirectMonitorIsIsolatedAndRestoredInBothAuditionBackends() throws {
        for shared in [false, true] {
            let studio = AudioEngine()
            let engine = studio.engine
            let format = try XCTUnwrap(AVAudioFormat(
                standardFormatWithSampleRate: studio.sampleRate, channels: 2
            ))
            let player = AVAudioPlayerNode()
            let rackSum = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(rackSum)
            engine.connect(player, to: rackSum, format: format)
            studio.registerVRackSumMixer(rackSum)
            let dryMonitor = engine.outputConnectionPoints(
                for: rackSum, outputBus: 0
            ).compactMap { $0.node as? AVAudioMixerNode }.first
            XCTAssertNotNil(dryMonitor, "V-Rack must have its original monitor")
            studio.setVRackCaptureSourcePresent(true)
            studio.setSharedMicrophoneMatrixEnabled(shared)

            // Completely mute microphone channels and the shared hall.
            // Any non-silent signal in audition would therefore be a
            // leakage of the V-Rack's original dry monitor path.
            let room = StudioAcousticRoomDesign()
            let center = StudioMicrophoneGeometry.approximateTrackPosition(
                pan: 0, zone: 2, room: room
            )
            var mic = StudioVirtualMicrophone(
                position: StudioRoomPosition3D(
                    xMeters: center.xMeters,
                    yMeters: max(0, center.yMeters - 1),
                    zMeters: center.zMeters
                ),
                pattern: .omnidirectional
            )
            mic.mixerSettings = StudioMicrophoneChannelSettings(level: 1)
            studio.setMicrophoneRoomWetLevel(0)
            try studio.setMicrophoneAuditionEnabled(
                true, tracks: [], microphones: [mic], room: room
            )
            XCTAssertTrue(studio.isMicrophoneAuditionActive)
            let rackConnections = engine.outputConnectionPoints(
                for: rackSum, outputBus: 0
            )
            XCTAssertEqual(rackConnections.count, 1,
                           "Rack sum must exclusively feed its mic capture AU")
            XCTAssertEqual(dryMonitor?.outputVolume ?? -1, 0,
                           "Disconnected direct V-Rack monitor must start muted")
            let captureNode = rackConnections.compactMap {
                $0.node as? AVAudioUnitEffect
            }.first
            XCTAssertNotNil(captureNode, "Rack sum must connect to the mic AU")
            if let captureNode {
                // V-Rack always uses its four-output matrix, including
                // when other tracks use the legacy capture backend.
                let gainAddress = NativeMicrophoneMatrixAudioUnit.gainAddress(0)
                let actualGain = captureNode.auAudioUnit.parameterTree?
                    .parameter(withAddress: gainAddress)?.value ?? 0
                XCTAssertGreaterThan(abs(actualGain), 0.01,
                    "Rack capture AU must receive a nonzero microphone pickup gain")
                let capsuleOutputs = engine.outputConnectionPoints(
                    for: captureNode, outputBus: 0
                )
                let micChannel = capsuleOutputs.first?.node as? AVAudioMixerNode
                XCTAssertNotNil(micChannel, "Capsule must reach a microphone channel")
                if let micChannel {
                    XCTAssertGreaterThan(micChannel.outputVolume, 0.9,
                        "Microphone channel must be unmuted at audition start")
                    let channelOutputs = engine.outputConnectionPoints(
                        for: micChannel, outputBus: 0
                    )
                    let micMaster = channelOutputs.first?.node as? AVAudioMixerNode
                    XCTAssertNotNil(micMaster, "Mic channel must reach mic master")
                    XCTAssertGreaterThan(micMaster?.outputVolume ?? -1, 0.9,
                        "Mic master bus must be enabled")
                }
            }
            XCTAssertGreaterThan(rackSum.outputVolume, 0.9,
                "Rack sum must stay at unity for microphone and recording taps")

            // AudioEngine prepares its device graph during initialization.
            // Offline rendering may only be enabled after a full stop.
            engine.stop()
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 512
            )
            try engine.start()
            let input = try makeInput(format)
            player.scheduleBuffer(input, at: nil, options: [.loops])
            player.play()
            let initialMicPeak = try renderPeak(engine)
            XCTAssertGreaterThan(initialMicPeak, 0.01,
                "The V-Rack microphone must sound on initial graph construction")

            // Mute only the microphone channel. There must be no other
            // connected V-Rack direct monitor signal during audition.
            mic.mixerSettings = StudioMicrophoneChannelSettings(level: 0)
            studio.refreshMicrophoneRouting(
                tracks: [], microphones: [mic], room: room
            )
            let mutedPeak = try renderPeak(engine)
            XCTAssertLessThan(mutedPeak, 0.0001,
                "Audition must not double a direct V-Rack signal")

            // Restore the channel live without reopening rack direct monitoring.
            mic.mixerSettings = StudioMicrophoneChannelSettings(level: 1)
            studio.refreshMicrophoneRouting(
                tracks: [], microphones: [mic], room: room
            )
            let audibleMicPeak = try renderPeak(engine)
            XCTAssertGreaterThan(audibleMicPeak, 0.01,
                "The V-Rack microphone must remain audible after unmuting")
            engine.stop()
            player.stop()

            // Return to original monitoring; the rack sum stays connected.
            try studio.setMicrophoneAuditionEnabled(
                false, tracks: [], microphones: [], room: StudioAcousticRoomDesign()
            )
            XCTAssertFalse(studio.isMicrophoneAuditionActive)
            try engine.start()
            player.scheduleBuffer(input, at: nil, options: [.loops])
            player.play()
            let originalPeak = try renderPeak(engine)
            XCTAssertGreaterThan(originalPeak, 0.05,
                "The original V-Rack route must return after audition")
            engine.stop()
            player.stop()
        }
    }

    /// Standalone host reproduction: identify whether a mixer can feed the
    /// native four-output AU before introducing Studio's hall/mic returns.
    func testMixerOutputFeedsFourBusCaptureInSmallAVAudioEngine() throws {
        NativeMicrophoneMatrixAudioUnit.registerIfNeeded()
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2
        ))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let source = AVAudioMixerNode()
        let capture = AVAudioUnitEffect(
            audioComponentDescription: NativeMicrophoneMatrixAudioUnit.componentDescription
        )
        engine.attach(player)
        engine.attach(source)
        engine.attach(capture)
        engine.connect(player, to: source, format: format)
        engine.connect(source, to: capture, format: format)
        let channels = (0..<4).map { _ in AVAudioMixerNode() }
        for (index, channel) in channels.enumerated() {
            engine.attach(channel)
            engine.connect(capture, to: channel,
                           fromBus: AVAudioNodeBus(index),
                           toBus: channel.nextAvailableInputBus, format: format)
            engine.connect(channel, to: engine.mainMixerNode, format: format)
            channel.outputVolume = index == 0 ? 1 : 0
        }
        capture.auAudioUnit.parameterTree?.parameter(
            withAddress: NativeMicrophoneMatrixAudioUnit.gainAddress(0)
        )?.value = 1
        capture.auAudioUnit.parameterTree?.parameter(
            withAddress: NativeMicrophoneMatrixAudioUnit.filterAddress(0)
        )?.value = 1
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 512
        )
        try engine.start()
        defer { engine.stop() }
        let input = try makeInput(format)
        player.scheduleBuffer(input, at: nil, options: [.loops])
        player.play()
        XCTAssertGreaterThan(try renderPeak(engine), 0.01,
                             "Four-output capture must accept mixer input")
    }

    /// Isolate which edge of Studio's prepared master graph is failing.
    /// The normal independent matrix/mixer test above already passes.
    func testPreparedStudioGraphAcceptsDirectMicrophoneAndCaptureInputs() throws {
        for feedCapture in [false, true] {
            let studio = AudioEngine()
            let engine = studio.engine
            let format = try XCTUnwrap(AVAudioFormat(
                standardFormatWithSampleRate: studio.sampleRate, channels: 2
            ))
            let source = AVAudioMixerNode()
            let player = AVAudioPlayerNode()
            engine.attach(source)
            engine.attach(player)
            engine.connect(player, to: source, format: format)
            studio.registerVRackSumMixer(source)
            studio.setVRackCaptureSourcePresent(true)
            studio.setSharedMicrophoneMatrixEnabled(true)

            let room = StudioAcousticRoomDesign()
            let stage = StudioMicrophoneGeometry.approximateTrackPosition(
                pan: 0, zone: 2, room: room
            )
            let mic = StudioVirtualMicrophone(
                position: StudioRoomPosition3D(
                    xMeters: stage.xMeters, yMeters: stage.yMeters,
                    zMeters: stage.zMeters
                ),
                pattern: .omnidirectional,
                mixerSettings: StudioMicrophoneChannelSettings(level: 1)
            )
            try studio.setMicrophoneAuditionEnabled(
                true, tracks: [], microphones: [mic], room: room
            )
            let capture = try XCTUnwrap(
                engine.outputConnectionPoints(for: source, outputBus: 0)
                    .first?.node as? AVAudioUnitEffect
            )
            let micChannel = try XCTUnwrap(
                engine.outputConnectionPoints(for: capture, outputBus: 0)
                    .first?.node as? AVAudioMixerNode
            )
            if feedCapture {
                engine.connect(player, to: capture, format: format)
            } else {
                engine.connect(player, to: micChannel, format: format)
            }
            engine.stop()
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 512
            )
            try engine.start()
            let input = try makeInput(format)
            player.scheduleBuffer(input, at: nil, options: [.loops])
            player.play()
            let peak = try renderPeak(engine)
            XCTAssertGreaterThan(
                peak, 0.01,
                feedCapture
                    ? "Studio matrix capture/mic master path should render"
                    : "Studio microphone return mixer should render"
            )
            engine.stop()
            player.stop()
        }
    }

    func testRackOnlyMIDITracksAreCountedThroughRackAggregate() {
        let rackID = UUID()
        var tracks: [Track] = []
        for index in 0..<32 {
            var track = Track(name: "Rack MIDI \(index)", type: .midi)
            track.midiOutput = .rackInstrument(id: rackID, channel: 1)
            tracks.append(track)
        }
        XCTAssertTrue(tracks.allSatisfy {
            !AudioEngine.isIndependentMicrophoneSource($0)
        })

        let independentMIDI = Track(name: "Standalone MIDI", type: .midi)
        XCTAssertTrue(AudioEngine.isIndependentMicrophoneSource(independentMIDI))
        var audio = Track(name: "Audio Track", type: .audio)
        audio.midiOutput = .rackInstrument(id: rackID, channel: 1)
        XCTAssertTrue(AudioEngine.isIndependentMicrophoneSource(audio))
    }

    func testAddingOrRemovingRackDuringAuditionReturnsToOriginalMix() throws {
        let studio = AudioEngine()
        let engine = studio.engine
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: studio.sampleRate, channels: 2
        ))
        let rackSum = AVAudioMixerNode()
        let player = AVAudioPlayerNode()
        engine.attach(rackSum)
        engine.attach(player)
        engine.connect(player, to: rackSum, format: format)
        studio.registerVRackSumMixer(rackSum)
        studio.setVRackCaptureSourcePresent(true)
        try studio.setMicrophoneAuditionEnabled(
            true, tracks: [], microphones: [StudioVirtualMicrophone()],
            room: StudioAcousticRoomDesign()
        )
        XCTAssertTrue(studio.isMicrophoneAuditionActive)
        studio.setVRackCaptureSourcePresent(false)
        XCTAssertFalse(studio.isMicrophoneAuditionActive)
        XCTAssertFalse(studio.hasVRackCaptureSource)
        XCTAssertEqual(
            engine.outputConnectionPoints(for: rackSum, outputBus: 0).count, 1,
            "The independent dry-monitor connection must survive rollback"
        )
    }
}
