import SwiftUI
import DAWUI

/// Browsable reference sheet for the icon identities in the GPO5 instrument
/// catalog. This is a design gallery, not an instrument-loading interface.
struct StudioIconGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studioPalette) private var palette
    @Environment(\.studioIconCollection) private var activeCollection
    @AppStorage("garritanStudio.iconCollection") private var collection =
        StudioIconCollection.matchAppearance.rawValue

    private struct IconFamily: Identifiable {
        let name: String
        let instruments: [String]
        var id: String { name }
    }

    private let families: [IconFamily] = [
        IconFamily(name: "Strings", instruments: [
            "Violin", "Viola", "Cello", "Double Bass", "String Ensemble"
        ]),
        IconFamily(name: "Woodwinds", instruments: [
            "Piccolo", "Flute", "Alto Flute", "Bass Flute",
            "Oboe", "English Horn", "Clarinet", "Bass Clarinet",
            "Contrabass Clarinet", "Bassoon", "Contrabassoon"
        ]),
        IconFamily(name: "Brass", instruments: [
            "Piccolo Trumpet", "C Trumpet", "Bb Trumpet", "French Horn",
            "Alto Trombone", "Tenor Trombone", "Bass Trombone",
            "Tuba", "Contrabass Tuba", "Brass Ensemble"
        ]),
        IconFamily(name: "Pitched Percussion", instruments: [
            "Timpani", "Glockenspiel", "Xylophone", "Vibraphone",
            "Marimba", "Crotales", "Tubular Bells", "Handbells"
        ]),
        IconFamily(name: "Orchestral Percussion", instruments: [
            "Snare Drum", "Bass Drum", "Cymbals", "Triangle",
            "Gong", "Tambourine", "Maracas", "Castanets",
            "Cowbell", "Sleigh Bells", "Mark Tree", "Ratchet",
            "Gourd", "Claves", "Cabasa", "Vibraslap",
            "Woodblock", "Wind Machine"
        ]),
        IconFamily(name: "Keyboards & Harp", instruments: [
            "Concert Grand Harp", "Concert Grand Piano", "Harpsichord",
            "Celesta", "Glass Armonica", "Pipe Organ"
        ]),
        IconFamily(name: "Other", instruments: [
            "Choir", "Synth Pad", "World Instrument", "Full Orchestra"
        ])
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Garritan Studio Instrument Icons")
                        .font(.system(size: 23, weight: .semibold,
                                      design: palette.appearance == .gpo5Modern ?
                                      .default : .serif))
                    Text("Browse the icon identities used for GPO5 and Instant Orchestra patches.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Picker("Icon Collection", selection: $collection) {
                    ForEach(StudioIconCollection.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .frame(width: 230)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(palette.panel)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 25) {
                    ForEach(families) { family in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(family.name.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(1.5)
                                    .foregroundStyle(palette.accent)
                                Rectangle()
                                    .fill(palette.separator)
                                    .frame(height: 1)
                            }
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: 12),
                                    count: 5
                                ),
                                spacing: 12
                            ) {
                                ForEach(family.instruments, id: \.self) { instrument in
                                    VStack(spacing: 9) {
                                        StudioInstrumentIcon(name: instrument, size: 64)
                                            .frame(height: 75)
                                        Text(instrument)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(palette.primaryText)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(height: 31)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 5)
                                    .background(
                                        palette.surface,
                                        in: RoundedRectangle(cornerRadius: 11)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11)
                                            .strokeBorder(palette.separator.opacity(0.75),
                                                          lineWidth: 1)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
            .background(palette.canvas)
            Divider()
            HStack {
                Text("Active icon style: \(activeCollection.title)")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text("Illustrations are vector-drawn and scale with the interface.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(palette.panel)
        }
        .frame(width: 920, height: 740)
        .tint(palette.accent)
    }
}
