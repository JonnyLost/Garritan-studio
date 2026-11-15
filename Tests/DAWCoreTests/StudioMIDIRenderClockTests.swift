import XCTest
import AVFoundation
import Combine
@testable import DAWCore

final class StudioMIDIRenderClockTests: XCTestCase {
    @MainActor
    func testSilentClockSourceAdvancesInManualRenderWithoutAudibleInput() throws {
        let studio = AudioEngine()
        let rate = studio.sampleRate
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try studio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        try studio.engine.start()
        defer { studio.engine.stop(); studio.engine.disableManualRenderingMode() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        let generation = studio.midiClock.begin(at: 1000)
        for _ in 0..<3 {
            XCTAssertEqual(try studio.engine.renderOffline(256, to: buffer), .success)
        }
        let snapshot = try XCTUnwrap(studio.midiClock.snapshot())
        XCTAssertEqual(snapshot.generation, generation)
        XCTAssertEqual(snapshot.endFrame, 1768)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) { XCTAssertEqual(data[channel][frame], 0) }
        }
        studio.midiClock.cancel()
        XCTAssertEqual(try studio.engine.renderOffline(256, to: buffer), .success)
        XCTAssertNil(studio.midiClock.snapshot())
        let next = studio.midiClock.begin(at: 8000)
        XCTAssertEqual(try studio.engine.renderOffline(256, to: buffer), .success)
        XCTAssertEqual(studio.midiClock.snapshot()?.generation, next)
        XCTAssertEqual(studio.midiClock.snapshot()?.endFrame, 8256)
    }

    @MainActor
    func testTransportEventsAreSynchronousAcrossSeekStopRestart() {
        let transport = TransportState()
        var playing = false
        var preparedAt: [Double] = []
        let subscription = transport.transportEventSubject.sink { event in
            switch event {
            case .play:
                playing = true
                preparedAt.append(transport.playbackStartBeat)
            case .pause, .stop: playing = false
            default: break
            }
        }
        defer { subscription.cancel(); transport.stop() }
        transport.play()
        XCTAssertTrue(playing)
        transport.pause()
        transport.setPlayheadBeats(8)
        transport.play()
        transport.stop()
        // These assertions occur before any main-queue dispatch can run.
        XCTAssertFalse(playing)
        XCTAssertFalse(transport.isPlaying)
        transport.setPlayheadBeats(2)
        transport.play()
        XCTAssertTrue(playing)
        XCTAssertEqual(preparedAt, [0, 8, 2])
        transport.stop()
        XCTAssertFalse(playing)
    }
}
