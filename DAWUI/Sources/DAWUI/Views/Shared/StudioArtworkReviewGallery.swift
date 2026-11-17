import SwiftUI

#if DEBUG
/// QA-only artwork gallery. Displays every real SwiftUI vector identity,
/// not a generated poster or a guessed bank-patch list.
///
/// Open the `Studio Artwork — All identities` Xcode Preview to review all
/// instrument and ensemble drawings at typical track (24 pt) and browser
/// (88 pt) sizes, and across every supported visual collection.
///
/// This view is excluded from release builds and never changes project data.
struct StudioArtworkReviewGallery: View {
    @State private var showEnsembles = false
    @State private var iconCollection = StudioIconCollection.heritageEtching
    @State private var largeIcons = true

    private let columns = [
        GridItem(.adaptive(minimum: 142, maximum: 210), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Studio Artwork Review")
                .font(.title2.bold())
            Text("Native geometry only • inspect solos and sections independently")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Picker("Category", selection: $showEnsembles) {
                    Text("Solo / family (\(InstrumentIconIdentity.allCases.count))")
                        .tag(false)
                    Text("Section / ensemble (\(StudioInstrumentGroupArtwork.allCases.count))")
                        .tag(true)
                }
                .pickerStyle(.segmented)

                Picker("Style", selection: $iconCollection) {
                    ForEach(StudioIconCollection.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .frame(width: 200)

                Toggle("Browser size", isOn: $largeIcons)
                    .toggleStyle(.checkbox)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    if showEnsembles {
                        ForEach(StudioInstrumentGroupArtwork.allCases, id: \.rawValue) { group in
                            tile(label: group.accessibilityLabel) {
                                StudioInstrumentIcon(
                                    reviewGroup: group,
                                    size: largeIcons ? 88 : 24
                                )
                            }
                        }
                    } else {
                        ForEach(InstrumentIconIdentity.allCases, id: \.self) { identity in
                            tile(label: identity.accessibilityLabel) {
                                StudioInstrumentIcon(
                                    reviewIdentity: identity,
                                    size: largeIcons ? 88 : 24
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 680)
        .environment(\.studioIconCollection, iconCollection)
    }

    private func tile<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            content()
                .frame(width: 100, height: 102)
            Text(label)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Studio Artwork — All identities") {
    StudioAppearanceHost {
        StudioArtworkReviewGallery()
    }
}
#endif
