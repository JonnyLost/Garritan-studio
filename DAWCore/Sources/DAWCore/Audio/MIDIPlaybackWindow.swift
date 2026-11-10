import Foundation

/// Pure timing decision used by the MIDI worker. The session lower bound
/// prevents older notes from sounding after a seek, while the upper bound
/// catches events even if their worker callback arrived late.
public struct MIDIPlaybackWindow: Sendable {
    public enum Disposition: Sendable, Equatable {
        case beforeSession
        case due
        case future
    }

    public let sessionStartBeat: Double
    public let bufferEndBeat: Double

    public init(sessionStartBeat: Double, bufferEndBeat: Double) {
        self.sessionStartBeat = sessionStartBeat
        self.bufferEndBeat = bufferEndBeat
    }

    public func disposition(for eventBeat: Double) -> Disposition {
        if eventBeat < sessionStartBeat { return .beforeSession }
        if eventBeat < bufferEndBeat { return .due }
        return .future
    }
}
