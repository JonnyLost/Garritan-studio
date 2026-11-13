import Foundation
import DAWCore

/// A typed, project-scoped bridge between the visible composing view and
/// Studio's document controller. Unlike global save-request notifications,
/// it cannot accidentally return another window's project snapshot.
@MainActor
public final class StudioProjectSnapshotBridge {
    private var registeredProjectID: UUID?
    private var snapshotProvider: (@MainActor () -> Project?)?
    private var clearPluginProvider: (@MainActor () -> Void)?
    private var restorePluginProvider: (@MainActor () -> Void)?

    public init() {}

    public func register(
        projectID: UUID,
        provider: @escaping @MainActor () -> Project?,
        clearPlugins: (@MainActor () -> Void)? = nil,
        restorePlugins: (@MainActor () -> Void)? = nil
    ) {
        registeredProjectID = projectID
        snapshotProvider = provider
        clearPluginProvider = clearPlugins
        restorePluginProvider = restorePlugins
    }

    public func unregister(projectID: UUID) {
        guard registeredProjectID == projectID else { return }
        registeredProjectID = nil
        snapshotProvider = nil
        clearPluginProvider = nil
        restorePluginProvider = nil
    }

    /// Ignore commands originating from a session which is no longer active.
    @discardableResult
    public func clearPlugins(for projectID: UUID) -> Bool {
        guard registeredProjectID == projectID,
              let clearPluginProvider else { return false }
        clearPluginProvider()
        return true
    }

    @discardableResult
    public func restorePlugins(for projectID: UUID) -> Bool {
        guard registeredProjectID == projectID,
              let restorePluginProvider else { return false }
        restorePluginProvider()
        return true
    }

    public func snapshot(for projectID: UUID) -> Project? {
        guard registeredProjectID == projectID else { return nil }
        let result = snapshotProvider?()
        guard result?.id == projectID else { return nil }
        return result
    }
}
