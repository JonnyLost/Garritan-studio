import XCTest
@testable import DAWCore

final class StudioAnalogRoutingTests: XCTestCase {
    func testFactoryRoutesMatchNativeCompiler() throws {
        let synth = try StudioAnalogInstrument(sampleRate: 44_100)
        XCTAssertTrue(StudioAnalogConnection.preliminarilyValid(StudioAnalogConnection.factory))
        XCTAssertEqual(StudioAnalogConnection.factory.count, 9)
        XCTAssertEqual(StudioAnalogModule.allCases.count, 10)
        try synth.setRouting(StudioAnalogConnection.factory)
        XCTAssertThrowsError(try synth.setRouting(StudioAnalogConnection.factory)) { error in
            guard case StudioAnalogError.routingBusy = error else {
                XCTFail("Expected pending graph back pressure, got \(error)")
                return
            }
        }
    }

    func testCableTypingAndDestinationInputUniqueness() {
        let correct = StudioAnalogConnection(source: .lfo, destination: .filter,
                                             input: 2)
        XCTAssertTrue(correct.isLocallyValid)
        let bad = StudioAnalogConnection(source: .oscillator1, destination: .filter,
                                         input: 2)
        XCTAssertFalse(bad.isLocallyValid)
        let duplicate = StudioAnalogConnection.factory + [StudioAnalogConnection(
            source: .oscillator2, destination: .mixer, input: 0)]
        XCTAssertFalse(StudioAnalogConnection.preliminarilyValid(duplicate))
    }

    func testAnalogCableRoundTripAndFactoryFallback() throws {
        var patch = StudioAnalogPatch()
        XCTAssertEqual(patch.activeConnections, StudioAnalogConnection.factory)
        let custom = [
            StudioAnalogConnection(source: .oscillator1, destination: .filter,
                                   input: 0, gain: 0.5),
            StudioAnalogConnection(source: .filter, destination: .vca, input: 0),
            StudioAnalogConnection(source: .amplitudeEnvelope, destination: .vca,
                                   input: 1),
            StudioAnalogConnection(source: .vca, destination: .output, input: 0)
        ]
        patch.connections = custom
        let encoded = try JSONEncoder().encode(patch)
        XCTAssertEqual(try JSONDecoder().decode(StudioAnalogPatch.self,
                                                from: encoded).activeConnections, custom)
        patch.reset()
        XCTAssertEqual(patch.activeConnections, StudioAnalogConnection.factory)

        // Version 1 patches had only values and version keys.
        let legacy = Data(#"{"version":1,"values":{"6":1200.0}}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioAnalogPatch.self, from: legacy)
        XCTAssertEqual(decoded.value(for: .filterCutoff), 1200)
        XCTAssertEqual(decoded.activeConnections, StudioAnalogConnection.factory)
    }
}
