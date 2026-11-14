import Foundation

/// Control-domain serialization for the opt-in Core Audio backend.
///
/// Only control-thread operations use this lock. The audio callback must
/// never invoke this gate, wait for it, or acquire another blocking primitive.
/// Reentrancy allows a public transport command to call the quiescent
/// parameter-queue drain without nesting a second independent lock.
final class StudioGraphControlGate {
    private let lock = NSRecursiveLock()

    @discardableResult
    func perform<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
