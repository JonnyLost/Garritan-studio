import Foundation

/// Lightweight control messages for the experimental Studio Core Audio graph.
/// One serialized control producer; one audio-render consumer. Topology edits
/// remain separate and require a drained callback.
enum StudioGraphParameterCommand {
    case trackVolume(TrackID, Float)
    case trackPan(TrackID, Float)
    case trackMute(TrackID, Bool)
    case masterVolume(Float)
}

/// Preallocated producer/consumer handoff. No dispatch, locks or waiting
/// inside the render callback. The caller owns serialization of submissions.
/// A drained control thread may temporarily consume the queue only after the
/// hardware render callback has completely stopped.
final class StudioGraphParameterMailbox {
    private let events: RingBuffer<StudioGraphParameterCommand>

    init(capacity: Int = 1024) {
        events = RingBuffer(capacity: capacity)
    }

    @discardableResult
    func submit(_ command: StudioGraphParameterCommand) -> Bool {
        events.push(command)
    }

    /// Consume no more than the allotted command budget in a single buffer.
    /// The callback is the sole consumer while audio output is active.
    func consume(maximum: Int = 128, _ apply: (StudioGraphParameterCommand) -> Void) {
        guard maximum > 0 else { return }
        for _ in 0..<maximum {
            guard let command = events.popAndReturn() else { break }
            apply(command)
        }
    }

    var pendingCount: Int { events.count }
}
