import Foundation

/// Control-only serialization for the experimental Core Audio backend.
/// The render callback never locks or even reads this object.
final class StudioGraphControlGate {
    private let lock = NSRecursiveLock()
    private var exclusiveBounce = false

    @discardableResult
    func perform<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    /// Reserve graph and AU resources across a suspending offline export.
    /// Only the control thread may begin/end a lease. The caller must drain
    /// the output callback before beginning any actual offline rendering.
    func beginBounceLease() -> Bool {
        perform {
            guard !exclusiveBounce else { return false }
            exclusiveBounce = true
            return true
        }
    }

    func endBounceLease() {
        perform { exclusiveBounce = false }
    }

    var isBounceActive: Bool { perform { exclusiveBounce } }

    /// A synchronous control transaction may not mutate graph resources
    /// while a leased offline renderer operates on the same AU instances.
    /// Returns false instead of ever blocking the real-time callback.
    @discardableResult
    func mutateIfAvailable(_ operation: () -> Void) -> Bool {
        perform {
            guard !exclusiveBounce else { return false }
            operation()
            return true
        }
    }

    /// Called under the same control gate by throwing API operations.
    func ensureMutationAvailable() throws {
        try perform {
            guard !exclusiveBounce else {
                throw StudioGraphLeaseError.exportInProgress
            }
        }
    }
}

enum StudioGraphLeaseError: Error, Equatable {
    case exportInProgress
    case alreadyExporting
}
