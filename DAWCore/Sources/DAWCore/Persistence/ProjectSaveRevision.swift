import Foundation

/// A revision token for one Studio document session.
///
/// The main actor owns changes to this value. A completed asynchronous save
/// acknowledges only the exact revision that was serialized. Edits made while
/// the disk operation is in flight remain dirty and eligible for autosave.
public struct ProjectSaveRevision: Sendable {
    public private(set) var current: UInt64 = 0
    public private(set) var saved: UInt64 = 0

    public init() {}

    public var hasUnsavedChanges: Bool { current != saved }

    public mutating func markChanged() {
        // Saturate instead of wrapping: a wrapped revision could accidentally
        // equal an old in-flight save token.
        if current < UInt64.max { current += 1 }
    }

    public func capture() -> UInt64 { current }

    /// True only if no further edits occurred since snapshot capture.
    @discardableResult
    public mutating func acknowledgeSave(snapshot revision: UInt64) -> Bool {
        guard revision == current else { return false }
        saved = current
        return true
    }

    /// Call after loading or constructing a different project, never during a save.
    public mutating func resetForNewSession() {
        current = 0
        saved = 0
    }
}
