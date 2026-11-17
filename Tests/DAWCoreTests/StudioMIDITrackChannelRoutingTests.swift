import XCTest
@testable import DAWCore

final class StudioMIDITrackChannelRoutingTests: XCTestCase {
    func testTransmitChannelAndInputFilterAreIndependent() {
        var track = Track(name: "ARIA Flute", type: .instrument)
        // Existing sessions retain their original MIDI event channel.
        XCTAssertNil(track.midiTransmitChannel)
        XCTAssertEqual(track.transmittedMIDIChannel(for: 9), 9)

        // A keyboard sending channel 10 can play an ARIA part on channel 1.
        track.midiOutputChannel = 9
        track.midiTransmitChannel = 0
        XCTAssertTrue(track.acceptsMIDIChannel(9))
        XCTAssertFalse(track.acceptsMIDIChannel(0))
        XCTAssertEqual(track.transmittedMIDIChannel(for: 9), 0)
    }

    func testWorkerCompilationUsesSameOutputChannelForNoteOffAndExpression() {
        var track = Track(name: "ARIA Part", type: .instrument)
        track.midiTransmitChannel = 0
        let destination = StudioMIDIDestination.track(track.id)
        let note = StudioMIDISessionEvent(
            clipID: ClipID(), absoluteBeat: 1,
            event: .note(at: 1, pitch: 60, duration: 1, channel: 9))
        let cc = StudioMIDISessionEvent(
            clipID: ClipID(), absoluteBeat: 1,
            event: .controlChange(at: 1, controller: 11, value: 95, channel: 9))

        let noteMessages = StudioMIDIFrameCompiler.messages(
            note, destination: destination, channel: track.midiTransmitChannel,
            tempo: 120, sampleRate: 44_100)
        let ccMessages = StudioMIDIFrameCompiler.messages(
            cc, destination: destination, channel: track.midiTransmitChannel,
            tempo: 120, sampleRate: 44_100)

        XCTAssertEqual(noteMessages.map(\.status), [0x90, 0x80])
        XCTAssertEqual(noteMessages.map(\.channel), [0, 0])
        XCTAssertEqual(ccMessages.map(\.status), [0xB0])
        XCTAssertEqual(ccMessages.first?.data1, 11)
        XCTAssertEqual(ccMessages.first?.data2, 95)
    }

    func testOldProjectsDecodeWithoutNewOutputChannelField() throws {
        var track = Track(name: "Legacy Flute", type: .instrument)
        track.midiTransmitChannel = 5
        let encoded = try JSONEncoder().encode(track)
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: encoded).midiTransmitChannel, 5)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "midiTransmitChannel")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let reopened = try JSONDecoder().decode(Track.self, from: legacy)
        XCTAssertNil(reopened.midiTransmitChannel)
        XCTAssertEqual(reopened.transmittedMIDIChannel(for: 9), 9)
    }
}
