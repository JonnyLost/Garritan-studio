import SwiftUI

// MARK: - Garritan Studio Appearance

/// A single appearance preference applies to the entire app; audio/project
/// state remains independent of the selected theme.
public enum StudioAppearance: String, CaseIterable, Identifiable {
    case system
    case heritageLight
    case gpo5Modern
    case heritageDark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Follow macOS"
        case .heritageLight: return "Personal Orchestra"
        case .gpo5Modern: return "GPO5 Modern"
        case .heritageDark: return "Orchestral Strings"
        }
    }

    public var subtitle: String {
        switch self {
        case .system: return "Automatically use Heritage Light or Heritage Dark"
        case .heritageLight: return "Heritage Light · ivory and warm gold"
        case .gpo5Modern: return "Modern · graphite and crisp white"
        case .heritageDark: return "Heritage Dark · charcoal and antique gold"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .heritageLight: return .light
        case .gpo5Modern, .heritageDark: return .dark
        }
    }

    public static let visualThemes: [StudioAppearance] = [
        .heritageLight, .gpo5Modern, .heritageDark
    ]
}

/// Semantic design tokens. Views use these rather than hard-coded colors,
/// making every visual theme share the same controls and layout.
public struct StudioPalette {
    public let appearance: StudioAppearance
    public let canvas: Color
    public let panel: Color
    public let sidebar: Color
    public let surface: Color
    public let raisedSurface: Color
    public let separator: Color
    public let accent: Color
    public let accentMuted: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let selectedBackground: Color
    public let selectedText: Color

    public init(appearance: StudioAppearance) {
        // The system option is resolved by StudioAppearanceHost before
        // creating a palette. Default to the light heritage palette if a
        // palette is constructed directly with .system.
        let style = appearance == .system ? StudioAppearance.heritageLight : appearance
        self.appearance = style

        let tokens: Tokens
        switch style {
        case .heritageLight, .system:
            tokens = Tokens(
                canvas: 0xF0EBDF, panel: 0xFFFAF0, sidebar: 0xE9E1D2,
                surface: 0xF8F2E7, raised: 0xFFFFFF, separator: 0xD6C9B5,
                accent: 0x956E39, muted: 0xE9D8B8,
                text: 0x302B25, secondary: 0x736A5D,
                selected: 0xE4CEAA, selectedText: 0x302B25
            )
        case .gpo5Modern:
            tokens = Tokens(
                canvas: 0x14161A, panel: 0x202329, sidebar: 0x111317,
                surface: 0x282C33, raised: 0x333841, separator: 0x393E47,
                accent: 0xBBCDDE, muted: 0x374655,
                text: 0xF3F5F7, secondary: 0xA7ADB6,
                selected: 0x384A5E, selectedText: 0xFFFFFF
            )
        case .heritageDark:
            tokens = Tokens(
                canvas: 0x242320, panel: 0x302D29, sidebar: 0x1C1B1A,
                surface: 0x3A352F, raised: 0x494239, separator: 0x544B40,
                accent: 0xD6B47A, muted: 0x53442E,
                text: 0xEFE7D9, secondary: 0xB8AD9C,
                selected: 0x645035, selectedText: 0xFFF5E4
            )
        }

        canvas = Self.color(tokens.canvas)
        panel = Self.color(tokens.panel)
        sidebar = Self.color(tokens.sidebar)
        surface = Self.color(tokens.surface)
        raisedSurface = Self.color(tokens.raised)
        separator = Self.color(tokens.separator)
        accent = Self.color(tokens.accent)
        accentMuted = Self.color(tokens.muted)
        primaryText = Self.color(tokens.text)
        secondaryText = Self.color(tokens.secondary)
        selectedBackground = Self.color(tokens.selected)
        selectedText = Self.color(tokens.selectedText)
    }

    private struct Tokens {
        let canvas: UInt32
        let panel: UInt32
        let sidebar: UInt32
        let surface: UInt32
        let raised: UInt32
        let separator: UInt32
        let accent: UInt32
        let muted: UInt32
        let text: UInt32
        let secondary: UInt32
        let selected: UInt32
        let selectedText: UInt32
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}


// MARK: - Instrument Artwork Collections

/// These four renderers use the same instrument-specific vector geometry,
/// with treatment selected by appearance or a user override.
public enum StudioIconCollection: String, CaseIterable, Identifiable {
    case matchAppearance
    case heritageEtching
    case elegantMonoline
    case gpo5Signature
    case concertMedallion

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .matchAppearance: return "Match Appearance"
        case .heritageEtching: return "Heritage Etching"
        case .elegantMonoline: return "Elegant Monoline"
        case .gpo5Signature: return "GPO5 Signature"
        case .concertMedallion: return "Concert Medallions"
        }
    }

    public var detail: String {
        switch self {
        case .matchAppearance: return "Use the icons designed for the selected appearance"
        case .heritageEtching: return "Fine engraved instrument drawings"
        case .elegantMonoline: return "Clean, minimal orchestral outlines"
        case .gpo5Signature: return "Bolder, contemporary silhouettes"
        case .concertMedallion: return "Gold-toned instruments in circular cameos"
        }
    }

    public static func recommended(for appearance: StudioAppearance) -> StudioIconCollection {
        switch appearance {
        case .system, .heritageLight: return .elegantMonoline
        case .gpo5Modern: return .gpo5Signature
        case .heritageDark: return .concertMedallion
        }
    }
}

private struct StudioIconCollectionKey: EnvironmentKey {
    static let defaultValue = StudioIconCollection.elegantMonoline
}

public extension EnvironmentValues {
    var studioIconCollection: StudioIconCollection {
        get { self[StudioIconCollectionKey.self] }
        set { self[StudioIconCollectionKey.self] = newValue }
    }
}

private struct StudioPaletteKey: EnvironmentKey {
    static let defaultValue = StudioPalette(appearance: .heritageLight)
}

public extension EnvironmentValues {
    var studioPalette: StudioPalette {
        get { self[StudioPaletteKey.self] }
        set { self[StudioPaletteKey.self] = newValue }
    }
}

/// Observes the saved preference and injects the resolved theme into every
/// workspace. System mode follows the Mac's current light/dark appearance.
public struct StudioAppearanceHost<Content: View>: View {
    @AppStorage("garritanStudio.appearance") private var selection = StudioAppearance.system.rawValue
    @AppStorage("garritanStudio.iconCollection") private var iconSelection = StudioIconCollection.matchAppearance.rawValue
    @Environment(\.colorScheme) private var systemScheme

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let choice = StudioAppearance(rawValue: selection) ?? .system
        let resolved: StudioAppearance = choice == .system
            ? (systemScheme == .dark ? .heritageDark : .heritageLight)
            : choice
        let requestedIcons = StudioIconCollection(rawValue: iconSelection) ?? .matchAppearance
        let resolvedIcons = requestedIcons == .matchAppearance
            ? StudioIconCollection.recommended(for: resolved)
            : requestedIcons
        content
            .environment(\.studioPalette, StudioPalette(appearance: resolved))
            .environment(\.studioIconCollection, resolvedIcons)
            .preferredColorScheme(choice.preferredColorScheme)
    }
}
