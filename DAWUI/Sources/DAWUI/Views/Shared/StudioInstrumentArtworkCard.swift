import SwiftUI

/// Reusable, offline artwork surface for Studio's Cinematic Atelier visual language.
///
/// This is a procedural presentation surface, not a replacement for individually
/// approved watercolor illustrations. The instrument silhouette comes from the
/// shared identity resolver, so the browser and track icons remain consistent.
public struct StudioInstrumentArtworkCard: View {
    @Environment(\.studioPalette) private var palette

    private let name: String
    private let path: String
    private let category: String
    private let height: CGFloat

    public init(name: String, path: String = "", category: String = "", height: CGFloat = 166) {
        self.name = name
        self.path = path
        self.category = category
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 190
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.raisedSurface,
                                palette.panel,
                                palette.accent.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Subtle engraved rings: rendered locally and intentionally low
                // contrast so instrument identity remains the primary subject.
                Circle()
                    .strokeBorder(palette.accent.opacity(0.12), lineWidth: 1)
                    .frame(width: 184, height: 184)
                    .offset(x: geometry.size.width * 0.28, y: 28)
                Circle()
                    .strokeBorder(palette.accent.opacity(0.09), lineWidth: 1)
                    .frame(width: 124, height: 124)
                    .offset(x: geometry.size.width * 0.28, y: 28)

                StudioInstrumentIcon(
                    name: name,
                    path: path,
                    category: category,
                    size: compact ? 76 : 106
                )
                .frame(width: compact ? 84 : 116, height: compact ? 84 : 116)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.separator.opacity(0.65), lineWidth: 1)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Instrument illustration: \(name)")
    }
}
