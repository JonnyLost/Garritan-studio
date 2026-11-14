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

    private func renderPeak(_ engine: AVAudioEngine, count: Int = 6) throws -> Float {
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 512
        ))
        var peak: Float = 0
        for _ in 0..<count {
            let status = try engine.renderOffline(512, to: output)
            XCTAssertEqual(status, .success)
            let channels = try XCTUnwrap(output.floatChannelData)
            for sample in 0..<512 {
                XCTAssertTrue(channels[0][sample].isFinite)
                XCTAssertTrue(channels[1][sample].isFinite)
                peak = max(peak, abs(channels[0][sample]), abs(channels[1][sample]))
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
            mic.mixerSettings = StudioMicrophoneChannelSettings(level: 0)
            studio.setMicrophoneRoomWetLevel(0)
            try studio.setMicrophoneAuditionEnabled(
                true, tracks: [], microphones: [mic], room: room
            )
            XCTAssertTrue(studio.isMicrophoneAuditionActive)

            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 512
            )
            try engine.start()
            let input = try makeInput(format)
            player.scheduleBuffer(input, at: nil, options: [.loops])
            player.play()
            let mutedPeak = try renderPeak(engine)
            XCTAssertLessThan(mutedPeak, 0.0001,
                "Audition must not double a direct V-Rack signal")

            // Unmute only the synthetic microphone channel, without
            // reopening the original V-Rack direct-monitor path.
            mic.mixerSettings = StudioMicrophoneChannelSettings(level: 1)
            studio.refreshMicrophoneRouting(
                tracks: [], microphones: [mic], room: room
            )
            let audibleMicPeak = try renderPeak(engine)
            XCTAssertGreaterThan(audibleMicPeak, 0.01,
                "The V-Rack aggregate must actually reach the microphone channel")
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
        engine.attach(rackSum)
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
