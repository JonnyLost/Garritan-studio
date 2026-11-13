import SwiftUI

/// This lightweight local-only compatibility view is not reachable from the
/// standard Studio toolbar. It exists so the current window view can retain
/// stable sheet bindings while optional cloud UI is excluded from the build.
public struct AuthenticationView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
            Text("Local Studio")
                .font(.headline)
            Text("Cloud accounts are not part of this Studio build.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

public struct AccountSettingsView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.largeTitle)
            Text("Your music stays on this Mac")
                .font(.headline)
            Text("No cloud sign-in is required.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
