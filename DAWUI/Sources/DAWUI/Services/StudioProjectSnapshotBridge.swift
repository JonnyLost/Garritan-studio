import Foundation
import DAWCore

/// A typed, project-scoped bridge between the visible composing view and
/// Studio's document controller. Unlike global save-request notifications,
/// it cannot accidentally return another window's project snapshot.
@MainActor
public final class StudioProjectSnapshotBridge {
    private var registeredProjectID: UUID?
    private var snapshotProvider: (@MainActor () -> Project?)?
    private var prepareForSaveProvider: (@MainActor () -> Void)?
    private var clearPluginProvider: (@MainActor () -> Void)?
    private var restorePluginProvider: (@MainActor () -> Void)?

    public init() {}

    public func register(
        projectID: UUID,
        provider: @escaping @MainActor () -> Project?,
        prepareForSave: (@MainActor () -> Void)? = nil,
        clearPlugins: (@MainActor () -> Void)? = nil,
        restorePlugins: (@MainActor () -> Void)? = nil
    ) {
        registeredProjectID = projectID
        snapshotProvider = provider
        prepareForSaveProvider = prepareForSave
        clearPluginProvider = clearPlugins
        restorePluginProvider = restorePlugins
    }

    public func unregister(projectID: UUID) {
        guard registeredProjectID == projectID else { return }
        registeredProjectID = nil
        snapshotProvider = nil
        prepareForSaveProvider = nil
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

    /// Prepare the view's layout and Audio Unit state, then read its project
    /// synchronously. No global broadcast or fixed restoration delay is used.
    /// Invalid project IDs have no side effects on the active composing view.
    public func preparedSnapshot(for projectID: UUID) -> Project? {
        guard registeredProjectID == projectID else { return nil }
        prepareForSaveProvider?()
        return snapshot(for: projectID)
    }

    public func snapshot(for projectID: UUID) -> Project? {
        guard registeredProjectID == projectID else { return nil }
        let result = snapshotProvider?()
        guard result?.id == projectID else { return nil }
        return result
    }
}
