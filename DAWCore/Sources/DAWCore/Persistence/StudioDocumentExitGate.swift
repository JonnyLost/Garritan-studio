import Foundation

/// Serializes asynchronous close/quit decisions. Busy saves or cancelled/failed
/// negotiations never authorize teardown of the document.
@MainActor
public final class StudioDocumentExitGate {
    private var pending = false
    public init() {}
    public func request(isBusy: Bool, negotiate: () async -> Bool) async -> Bool {
        guard !isBusy, !pending else { return false }
        pending = true
        defer { pending = false }
        return await negotiate()
    }
}
