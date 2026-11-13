import AppKit
import SwiftUI

/// Intercepts a normal macOS window close, in addition to the separate
/// NSApplicationDelegate guard used on Quit. A forwarding delegate retains
/// SwiftUI's original window-delegate behavior for unrelated events.
struct StudioWindowCloseGuard: NSViewRepresentable {
    let appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView(frame: .zero)
        let coordinator = context.coordinator
        view.windowChanged = { [weak coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.install(on: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.windowChanged = nil
    }

    final class WindowProbeView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var appState: AppState?
        private weak var window: NSWindow?
        private weak var originalDelegate: (any NSWindowDelegate)?
        private var pendingConfirmation = false
        private var allowConfirmedClose = false

        init(appState: AppState) {
            self.appState = appState
        }

        func install(on candidate: NSWindow?) {
            guard let candidate else { return }
            if window !== candidate { detach() }
            guard candidate.delegate !== self else { return }
            window = candidate
            originalDelegate = candidate.delegate
            candidate.delegate = self
        }

        func detach() {
            if let window, window.delegate === self {
                window.delegate = originalDelegate
            }
            window = nil
            originalDelegate = nil
            pendingConfirmation = false
            allowConfirmedClose = false
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowConfirmedClose {
                allowConfirmedClose = false
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            guard !pendingConfirmation else { return false }
            guard let appState else { return true }
            guard appState.hasUnsavedChanges else {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }

            pendingConfirmation = true
            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender else { return }
                let allowed = await appState.confirmApplicationTermination()
                self.pendingConfirmation = false
                if allowed {
                    self.allowConfirmedClose = true
                    sender.performClose(nil)
                }
            }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector)
                || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true {
                return originalDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
