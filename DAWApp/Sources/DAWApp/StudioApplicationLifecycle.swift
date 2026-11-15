import AppKit
import Foundation

/// macOS application quit guard. A user-confirmed Save As may be asynchronous,
/// so AppKit waits for the final document decision before terminating Studio.
@MainActor
final class StudioApplicationLifecycle: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        guard appState.needsExitNegotiation else { return .terminateNow }

        Task { @MainActor in
            let confirmed = await appState.confirmApplicationTermination()
            sender.reply(toApplicationShouldTerminate: confirmed)
        }
        return .terminateLater
    }
}
