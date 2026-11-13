import Foundation
import DAWCore

/// A typed, project-scoped bridge between the visible composing view and
/// Studio's document controller. Unlike global save-request notifications,
/// it cannot accidentally return another window's project snapshot.
@MainActor
public final class StudioProjectSnapshotBridge {
    private var registeredProjectID: UUID?
    private var snapshotProvider: (@MainActor () -> Project?)?

    public init() {}

    public func register(
        projectID: UUID,
        provider: @escaping @MainActor () -> Project?
    ) {
        registeredProjectID = projectID
        snapshotProvider = provider
    }

    public func unregister(projectID: UUID) {
        guard registeredProjectID == projectID else { return }
        registeredProjectID = nil
        snapshotProvider = nil
    }

    public func snapshot(for projectID: UUID) -> Project? {
        guard registeredProjectID == projectID else { return nil }
        let result = snapshotProvider?()
        guard result?.id == projectID else { return nil }
        return result
    }
}
