import SwiftUI

// MARK: - Shared Garritan Studio workspace language

/// Every editor has the same title, subtitle, accent rule, and trailing
/// actions. Workspaces retain their own functionality and layout below it.
public struct StudioWorkspaceHeader<Trailing: View>: View {
    @Environment(\.studioPalette) private var palette

    private let title: String
    private let subtitle: String
    private let symbol: String
    private let trailing: Trailing

    public init(
        _ title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 35, height: 35)
                .background(palette.accentMuted.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold,
                                  design: palette.appearance == .gpo5Modern ?
                                      .default : .serif))
                    .foregroundStyle(palette.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.panel)
        .overlay(alignment: .bottom) {
            palette.separator.frame(height: 1)
        }
    }
}

/// Consistent section headings used in Channel, Stage and the other editors.
public struct StudioSectionHeading: View {
    @Environment(\.studioPalette) private var palette

    private let title: String
    private let symbol: String

    public init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 18)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reusable softly bordered surface. Do not use on the live piano keyboard
/// keys, stage hotspots, or controls requiring their own hit testing.
private struct StudioPanelModifier: ViewModifier {
    @Environment(\.studioPalette) private var palette
    let emphasized: Bool

    func body(content: Content) -> some View {
        content
            .background(emphasized ? palette.raisedSurface : palette.panel,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.separator.opacity(0.8), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

public extension View {
    func studioPanel(emphasized: Bool = false) -> some View {
        modifier(StudioPanelModifier(emphasized: emphasized))
    }
}
