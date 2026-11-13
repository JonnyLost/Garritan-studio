import Foundation

/// Value-type session revision tracker. All state changes are made by the
/// main-actor document controller, not by the audio/render thread.
public struct StudioSessionSaveTicket: Sendable, Equatable {
    public let sessionID: UUID
    public let revision: UInt64

    public init(sessionID: UUID, revision: UInt64) {
        self.sessionID = sessionID
        self.revision = revision
    }
}

public struct StudioSessionRevision: Sendable {
    public private(set) var sessionID: UUID
    public private(set) var editRevision: UInt64
    public private(set) var savedRevision: UInt64

    public init() {
        sessionID = UUID()
        editRevision = 0
        savedRevision = 0
    }

    public var hasUnsavedChanges: Bool { editRevision != savedRevision }

    public mutating func markEdited() {
        editRevision &+= 1
    }

    public func saveTicket() -> StudioSessionSaveTicket {
        StudioSessionSaveTicket(sessionID: sessionID, revision: editRevision)
    }

    /// Accept a completed save only for the same session and never clear edits
    /// made after the snapshot was captured.
    @discardableResult
    public mutating func markSaved(_ ticket: StudioSessionSaveTicket) -> Bool {
        guard ticket.sessionID == sessionID,
              ticket.revision <= editRevision else { return false }
        savedRevision = max(savedRevision, ticket.revision)
        return !hasUnsavedChanges
    }

    /// A new/opened document invalidates any in-flight save receipts.
    public mutating func replaceSession() {
        sessionID = UUID()
        editRevision = 0
        savedRevision = 0
    }
}

/// Posted after the new composing view's audio engine has initialized.
/// Using a concrete project UUID prevents delayed old-window events from
/// restoring instruments into a different session.
public extension Notification.Name {
    static let studioSessionViewReady = Notification.Name("studioSessionViewReady")
}
