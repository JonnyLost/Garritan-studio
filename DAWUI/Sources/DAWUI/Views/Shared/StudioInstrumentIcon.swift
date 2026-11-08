import SwiftUI

// MARK: - Instrument-Specific Vector Icon System

/// Reusable, resolution-independent instrument art. One instrument identity can
/// appear in hundreds of GPO5 patches (solo, player, keyswitch and articulation)
/// without duplicating assets. Icon collection and color adapt to user settings.
public struct StudioInstrumentIcon: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.studioIconCollection) private var collection

    private let name: String
    private let path: String
    private let category: String
    private let dimension: CGFloat

    public init(name: String, path: String = "", category: String = "", size: CGFloat = 24) {
        self.name = name
        self.path = path
        self.category = category
        self.dimension = size
    }

    public var body: some View {
        let identity = InstrumentIconIdentity.resolve(name: name, path: path, category: category)
        let art = InstrumentIconDrawing.make(identity)
        let isCompact = dimension < 38

        Canvas(rendersAsynchronously: false) { graphics, bounds in
            var context = graphics
            context.scaleBy(x: bounds.width / 100, y: bounds.height / 100)

            let stroke: StrokeStyle
            let detailStroke: StrokeStyle
            let ink: Color
            let secondaryInk: Color
            let filledInk: Color

            switch collection {
            case .heritageEtching:
                // Sepia ink, hand-engraved detail, softly tinted instrument bodies.
                ink = palette.appearance == .heritageLight
                    ? Color(red: 0.37, green: 0.27, blue: 0.18)
                    : Color(red: 0.89, green: 0.74, blue: 0.52)
                secondaryInk = ink.opacity(0.72)
                filledInk = ink.opacity(0.13)
                stroke = StrokeStyle(lineWidth: 3.8, lineCap: .round, lineJoin: .round)
                detailStroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            case .elegantMonoline, .matchAppearance:
                // Minimal, even line weights with deliberate negative space.
                ink = palette.primaryText
                secondaryInk = palette.primaryText.opacity(0.8)
                filledInk = .clear
                stroke = StrokeStyle(lineWidth: 4.1, lineCap: .round, lineJoin: .round)
                detailStroke = StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            case .gpo5Signature:
                // Contemporary solid silhouettes with small contrasting highlights.
                ink = palette.primaryText
                secondaryInk = palette.accent
                filledInk = ink.opacity(0.90)
                stroke = StrokeStyle(lineWidth: 5.3, lineCap: .round, lineJoin: .round)
                detailStroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            case .concertMedallion:
                let gold = Color(red: 0.88, green: 0.70, blue: 0.41)
                let lightGold = Color(red: 0.99, green: 0.89, blue: 0.70)
                let darkField = Color(red: 0.10, green: 0.15, blue: 0.19)
                let field = Path(ellipseIn: CGRect(x: 2, y: 2, width: 96, height: 96))
                let inner = Path(ellipseIn: CGRect(x: 7, y: 7, width: 86, height: 86))
                let incised = Path(ellipseIn: CGRect(x: 12, y: 12, width: 76, height: 76))
                context.fill(field, with: .color(gold))
                context.fill(inner, with: .color(darkField))
                context.stroke(inner, with: .color(lightGold.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 2))
                if !isCompact {
                    context.stroke(incised, with: .color(gold.opacity(0.65)),
                                   style: StrokeStyle(lineWidth: 1))
                }
                context.translateBy(x: 17, y: 17)
                context.scaleBy(x: 0.66, y: 0.66)
                ink = lightGold
                secondaryInk = gold
                filledInk = gold.opacity(0.5)
                stroke = StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round)
                detailStroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            }

            // Draw from back to front. Silhouette fills are deliberately
            // separate from contour paths: open strokes must never be filled.
            if collection != .elegantMonoline && collection != .matchAppearance {
                for shape in art.silhouettes {
                    context.fill(shape, with: .color(filledInk))
                }
            }
            for shape in art.primary {
                context.stroke(shape, with: .color(ink), style: stroke)
            }
            // Tiny browser icons need high-contrast contours, not hairline
            // engraving. The larger inspector displays the complete artwork.
            if !isCompact {
                for shape in art.details {
                    context.stroke(shape, with: .color(secondaryInk), style: detailStroke)
                }
                if collection == .heritageEtching {
                    for shape in art.engraving {
                        context.stroke(shape, with: .color(secondaryInk.opacity(0.7)),
                                       style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
                    }
                }
            } else {
                // A restrained amount of detail survives in compact rows.
                for shape in art.compactDetails {
                    context.stroke(shape, with: .color(secondaryInk),
                                   style: StrokeStyle(lineWidth: 3.0, lineCap: .round))
                }
            }
        }
        .frame(width: dimension, height: dimension)
        .accessibilityLabel(Text(identity.accessibilityLabel))
        .accessibilityHidden(false)
    }
}

private enum InstrumentIconIdentity: Equatable {
    case piccolo, flute, altoFlute, bassFlute, oboe, englishHorn, clarinet, bassClarinet
    case contrabassClarinet, bassoon, contrabassoon
    case horn, trumpet, piccoloTrumpet, cTrumpet, bbTrumpet
    case trombone, altoTrombone, bassTrombone, tuba, contrabassTuba, brassEnsemble
    case violin, viola, cello, doubleBass, strings
    case timpani, snare, bassDrum, cymbals, triangle, gong, mallets, chimes, bells
    case xylophone, vibraphone, marimba, glockenspiel, crotales, handbells
    case tambourine, maracas, castanets, woodblock, windMachine
    case percussion, harp, piano, celesta, harpsichord, organ, glassArmonica
    case choir, synth, wind, world, orchestra, generic

    var accessibilityLabel: String {
        switch self {
        case .piccolo: return "Piccolo"
        case .flute: return "Flute"
        case .altoFlute: return "Alto flute"
        case .bassFlute: return "Bass flute"
        case .oboe: return "Oboe"
        case .englishHorn: return "English horn"
        case .clarinet: return "Clarinet"
        case .bassClarinet: return "Bass clarinet"
        case .contrabassClarinet: return "Contrabass clarinet"
        case .bassoon: return "Bassoon"
        case .contrabassoon: return "Contrabassoon"
        case .horn: return "French horn"
        case .trumpet: return "Trumpet"
        case .piccoloTrumpet: return "Piccolo trumpet"
        case .cTrumpet: return "C trumpet"
        case .bbTrumpet: return "B flat trumpet"
        case .trombone: return "Trombone"
        case .altoTrombone: return "Alto trombone"
        case .bassTrombone: return "Bass trombone"
        case .tuba: return "Tuba"
        case .contrabassTuba: return "Contrabass tuba"
        case .brassEnsemble: return "Brass section"
        case .violin: return "Violin"
        case .viola: return "Viola"
        case .cello: return "Cello"
        case .doubleBass: return "Double bass"
        case .strings: return "String section"
        case .timpani: return "Timpani"
        case .snare: return "Snare drum"
        case .bassDrum: return "Bass drum"
        case .cymbals: return "Cymbals"
        case .triangle: return "Triangle"
        case .gong: return "Gong"
        case .xylophone: return "Xylophone"
        case .vibraphone: return "Vibraphone"
        case .marimba: return "Marimba"
        case .glockenspiel: return "Glockenspiel"
        case .crotales: return "Crotales"
        case .handbells: return "Handbells"
        case .tambourine: return "Tambourine"
        case .maracas: return "Maracas"
        case .castanets: return "Castanets"
        case .woodblock: return "Woodblock"
        case .windMachine: return "Wind machine"
        case .mallets: return "Mallet percussion"
        case .chimes: return "Tubular bells"
        case .bells: return "Bells"
        case .percussion: return "Percussion"
        case .harp: return "Harp"
        case .piano: return "Piano"
        case .celesta: return "Celesta"
        case .harpsichord: return "Harpsichord"
        case .organ: return "Pipe organ"
        case .glassArmonica: return "Glass armonica"
        case .choir: return "Choir"
        case .synth: return "Synthesizer"
        case .wind: return "Wind instrument"
        case .world: return "World instrument"
        case .orchestra: return "Orchestra"
        case .generic: return "Musical instrument"
        }
    }

    static func resolve(name: String, path: String, category: String) -> Self {
        let n = name.lowercased()
        let context = (path + " " + category).lowercased()
        func has(_ fragments: [String]) -> Bool {
            fragments.contains(where: { n.contains($0) })
        }
        if has(["contrabass clarinet", "contrabassclarinet"]) { return .contrabassClarinet }
        if has(["bass clarinet"]) { return .bassClarinet }
        if has(["eb clarinet", "bb clarinet", "clarinet"]) { return .clarinet }
        if has(["english horn", "cor anglais"]) { return .englishHorn }
        if has(["contrabassoon", "contra bassoon"]) { return .contrabassoon }
        if has(["bassoon"]) { return .bassoon }
        if has(["oboe"]) { return .oboe }
        if has(["piccolo"]) && !has(["piccolo trumpet"]) { return .piccolo }
        if has(["alto flute"]) { return .altoFlute }
        if has(["bass flute"]) { return .bassFlute }
        if has(["flute"]) { return .flute }

        if has(["bass trombone", "contrabass trombone"]) { return .bassTrombone }
        if has(["alto trombone"]) { return .altoTrombone }
        if has(["trombone"]) { return .trombone }
        if has(["piccolo trumpet"]) { return .piccoloTrumpet }
        if has(["bb trumpet", "b-flat trumpet", "b♭ trumpet"]) { return .bbTrumpet }
        if has(["c trumpet"]) { return .cTrumpet }
        if has(["trumpet", "cornet"]) { return .trumpet }
        if has(["contrabass tuba", "contra tuba"]) { return .contrabassTuba }
        if has(["tuba", "euphonium"]) { return .tuba }
        if has(["french horn", "sam horn", "horns", "horn 1", "horn 2", "horn section"]) {
            return .horn
        }
        if has(["brass", "low brass"]) { return .brassEnsemble }

        if has(["violins", "violin", "fiddle"]) { return .violin }
        if has(["violas", "viola"]) { return .viola }
        if has(["cellos", "cello", "violoncello"]) { return .cello }
        if has(["double bass", "contrabass", "basses", "bass 1", "bass 2", "string bass"]) {
            return .doubleBass
        }
        if has(["full strings", "string section", "string ensemble", "short strings"]) {
            return .strings
        }

        if has(["timpani", "kettle drum"]) { return .timpani }
        if has(["snare", "side drum"]) { return .snare }
        if has(["bass drum", "gran cassa"]) { return .bassDrum }
        if has(["cymbal", "hi-hat"]) { return .cymbals }
        if has(["triangle"]) { return .triangle }
        if has(["gong", "tam tam", "tam-tam"]) { return .gong }
        if has(["tubular bell", "chime", "mark tree"]) { return .chimes }
        if has(["glockenspiel"]) { return .glockenspiel }
        if has(["crotale"]) { return .crotales }
        if has(["handbell"]) { return .handbells }
        if has(["xylophone"]) { return .xylophone }
        if has(["vibraphone"]) { return .vibraphone }
        if has(["marimba"]) { return .marimba }
        if has(["bell"]) { return .bells }
        if has(["tambourine"]) { return .tambourine }
        if has(["maracas", "shaker"]) { return .maracas }
        if has(["castanet"]) { return .castanets }
        if has(["woodblock", "wood block", "temple block", "clave"]) { return .woodblock }
        if has(["wind machine"]) { return .windMachine }
        if has(["percussion", "drum"]) {
            return .percussion
        }

        if has(["harpsichord"]) { return .harpsichord }
        if has(["harp"]) { return .harp }
        if has(["celesta", "celeste"]) { return .celesta }
        if has(["glass armonica", "glass harmonica"]) { return .glassArmonica }
        if has(["organ", "principal", "flute stop", "mixture stop"]) &&
           (context.contains("organ") || n.contains("organ")) { return .organ }
        if has(["piano", "concert d", "intimate d", "resonant b", "steinway", "grand"]) &&
            (context.contains("keyboard") || context.contains("piano") || has(["piano", "concert d", "intimate d", "resonant b", "steinway"])) {
            return .piano
        }

        if has(["soprano", "alto aah", "alto ooh", "tenor", "baritone", "boys choir",
                "children", "choir", "vocal", "bass aah", "bass ooh"]) { return .choir }
        if has(["synth", "pad", "analog", "electronic"]) { return .synth }
        if has(["orchestra", "unison orchestra"]) { return .orchestra }

        // Folder family fallback for more unusual GPO5 / Instant Orchestra patches.
        if context.contains("woodwind") { return .wind }
        if context.contains("brass") { return .brassEnsemble }
        if context.contains("string") { return .strings }
        if context.contains("percussion") { return .percussion }
        if context.contains("harp") { return .harp }
        if context.contains("keyboard") { return .piano }
        if context.contains("choir") { return .choir }
        if context.contains("synth") { return .synth }
        if context.contains("world") { return .world }
        return .generic
    }
}

private struct InstrumentIconDrawing {
    let primary: [Path]
    let details: [Path]
    let engraving: [Path]
    let silhouettes: [Path]
    let compactDetails: [Path]

    init(primary: [Path], details: [Path], engraving: [Path],
         silhouettes: [Path] = [], compactDetails: [Path] = []) {
        self.primary = primary
        self.details = details
        self.engraving = engraving
        self.silhouettes = silhouettes
        self.compactDetails = compactDetails
    }

    static func line(_ points: [(CGFloat, CGFloat)], closed: Bool = false) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.0, y: p.1)) }
        if closed { path.closeSubpath() }
        return path
    }

    static func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
    }

    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 3)
    }

    static func make(_ kind: InstrumentIconIdentity) -> Self {
        let base = makeBase(kind)
        return Self(
            primary: base.primary,
            details: base.details,
            engraving: base.engraving,
            silhouettes: fillShapes(for: kind, base: base),
            compactDetails: Array(base.details.prefix(4))
        )
    }

    /// Extra closed polygons that can be filled by Signature, Heritage and
    /// Medallion styles without filling open instrument strokes.
    private static func fillShapes(for kind: InstrumentIconIdentity,
                                   base: InstrumentIconDrawing) -> [Path] {
        switch kind {
        case .piccolo, .flute, .altoFlute, .bassFlute:
            return [line([(8, 75), (91, 25), (96, 31), (12, 81)], closed: true)]
        case .oboe, .englishHorn:
            return [line([(45, 22), (53, 20), (62, 82), (52, 83)], closed: true)]
        case .clarinet, .bassClarinet, .contrabassClarinet:
            return [line([(37, 13), (45, 10), (65, 78), (54, 82)], closed: true)]
        case .bassoon, .contrabassoon:
            return [box(30, 24, 10, 59), box(61, 19, 12, 63)]
        case .horn:
            return [line([(72, 25), (89, 17), (93, 14), (93, 77), (75, 70)],
                         closed: true)]
        case .trumpet, .piccoloTrumpet, .cTrumpet, .bbTrumpet:
            return [line([(69, 48), (93, 32), (93, 73), (69, 57)], closed: true)]
        case .trombone, .altoTrombone, .bassTrombone:
            return [line([(72, 40), (93, 24), (93, 58), (73, 47)], closed: true)]
        case .tuba, .contrabassTuba:
            return [line([(70, 16), (88, 6), (88, 30), (73, 28)], closed: true)]
        case .violin, .viola, .cello, .doubleBass, .strings:
            return Array(base.primary.prefix(1))
        case .timpani:
            return [line([(16, 39), (30, 72), (39, 80), (61, 80),
                          (72, 72), (84, 39)], closed: true)]
        case .snare, .bassDrum, .percussion:
            return [box(20, 35, 60, 37)]
        case .cymbals:
            return [oval(12, 20, 76, 22)]
        case .gong:
            return [oval(20, 15, 60, 60)]
        case .mallets, .xylophone, .vibraphone, .marimba, .bells, .glockenspiel:
            // Bars are thin enough that filling makes them readable at 24 px.
            return Array(base.primary.suffix(6))
        case .crotales:
            return Array(base.primary.prefix(5))
        case .handbells:
            return Array(base.primary.prefix(1))
        case .tambourine, .castanets, .maracas:
            return Array(base.primary.prefix(2))
        case .woodblock:
            return Array(base.primary.prefix(1))
        case .harp:
            return [line([(26, 89), (29, 18), (36, 16), (36, 89)], closed: true)]
        case .piano:
            return Array(base.primary.prefix(1))
        case .celesta, .harpsichord:
            return [box(12, 30, 76, 20)]
        case .organ:
            return Array(base.primary.prefix(5))
        case .glassArmonica:
            return [oval(25, 30, 49, 42)]
        case .choir:
            return Array(base.primary.prefix(3))
        case .synth:
            return [box(9, 22, 82, 60)]
        default:
            return []
        }
    }

    private static func makeBase(_ kind: InstrumentIconIdentity) -> Self {
        let L: ([(CGFloat, CGFloat)]) -> Path = { points in line(points) }
        let O = oval
        let B = box
        switch kind {
        case .piccolo, .flute, .altoFlute, .bassFlute:
            let right: CGFloat = kind == .piccolo ? 72 : 92
            var primary = [L([(9, 75), (right, 26)]), L([(12, 80), (right + 2, 31)])]
            var detail = [L([(15, 69), (15, 84)]), L([(right - 4, 22), (right + 5, 32)])]
            for i in 0..<5 {
                let x = CGFloat(28 + i * 10)
                detail.append(O(x, 71 - x * 0.52, 5, 5))
            }
            if kind == .altoFlute {
                primary.append(L([(12, 75), (6, 69), (8, 60), (19, 58)]))
            } else if kind == .bassFlute {
                primary.append(L([(12, 75), (8, 83), (21, 92), (32, 85)]))
            }
            return Self(primary: primary, details: detail, engraving: [L([(24, 72), (70, 45)])])
        case .oboe, .englishHorn:
            var primary = [
                L([(50, 9), (56, 21), (61, 78), (64, 85)]),
                L([(45, 21), (52, 80), (64, 88)]),
                L([(49, 9), (55, 9)])
            ]
            if kind == .englishHorn {
                primary.append(O(53, 79, 20, 12))
            } else {
                primary.append(L([(56, 86), (69, 92), (72, 88)]))
            }
            var detail: [Path] = []
            for index in 0..<5 {
                let step = CGFloat(index)
                let x: CGFloat = 48 + step
                let y: CGFloat = 31 + step * 9
                detail.append(O(x, y, 4, 4))
            }
            return Self(primary: primary, details: detail, engraving: [L([(48, 25), (56, 76)])])
        case .clarinet, .bassClarinet, .contrabassClarinet:
            var primary = [
                L([(38, 12), (56, 77)]),
                L([(44, 10), (63, 74)]),
                L([(54, 77), (47, 92), (77, 92), (64, 75)])
            ]
            if kind == .bassClarinet || kind == .contrabassClarinet {
                primary.append(L([(63, 75), (75, 80), (79, 88), (88, 86)]))
            }
            if kind == .contrabassClarinet {
                primary.append(L([(36, 24), (22, 30), (22, 67), (32, 72)]))
            }
            var detail: [Path] = []
            for index in 0..<5 {
                let step = CGFloat(index)
                let x: CGFloat = 43 + step * 2
                let y: CGFloat = 24 + step * 10
                detail.append(O(x, y, 5, 5))
            }
            return Self(primary: primary, details: detail, engraving: [L([(40, 22), (57, 70)])])
        case .bassoon, .contrabassoon:
            let primary = [
                L([(27, 82), (33, 25), (40, 21), (47, 82), (57, 82), (62, 18), (71, 15), (75, 80)]),
                L([(27, 82), (77, 82)]),
                L([(62, 18), (68, 8), (80, 12)])
            ]
            var detail = [L([(35, 28), (42, 73)]), L([(58, 30), (54, 74)])]
            for i in 0..<4 { detail.append(O(45, CGFloat(32+i*11), 5, 5)) }
            if kind == .contrabassoon { detail.append(O(15, 28, 66, 60)) }
            return Self(primary: primary, details: detail, engraving: [L([(32, 42), (33, 72)])])
        case .horn:
            var primary = [
                O(33, 22, 49, 53),
                O(44, 32, 24, 30),
                L([(20, 43), (35, 33), (36, 56), (25, 64)]),
                L([(20, 43), (9, 38), (9, 63), (26, 61)]),
                L([(72, 25), (89, 18), (90, 73), (75, 69)])
            ]
            primary.append(L([(47, 72), (39, 89), (53, 91), (62, 74)]))
            let detail = [L([(39, 18), (38, 31)]), L([(46, 19), (46, 30)]),
                          L([(53, 19), (54, 30)]), L([(37, 56), (52, 58), (65, 49)])]
            return Self(primary: primary, details: detail, engraving: [L([(47, 39), (63, 42)])])
        case .trumpet, .piccoloTrumpet, .cTrumpet, .bbTrumpet:
            var primary = [
                L([(8, 55), (73, 48), (91, 35), (91, 71), (73, 56), (8, 62)]),
                L([(18, 45), (18, 68)]), L([(18, 45), (64, 43), (64, 66), (18, 68)])
            ]
            var detail = [
                L([(38, 42), (38, 23), (45, 23), (45, 42)]),
                L([(49, 42), (49, 23), (56, 23), (56, 42)]),
                L([(59, 43), (59, 28), (66, 28), (66, 43)])
            ]
            if kind == .piccoloTrumpet {
                primary.append(L([(12, 40), (33, 31), (33, 44)]))
                detail.append(L([(17, 33), (20, 59)]))
            } else if kind == .bbTrumpet {
                primary.append(L([(21, 68), (23, 75), (73, 67)]))
            } else if kind == .cTrumpet {
                detail.append(L([(17, 40), (24, 33), (31, 39)]))
            }
            return Self(primary: primary, details: detail, engraving: [L([(26, 57), (68, 51)])])
        case .trombone, .altoTrombone, .bassTrombone:
            let primary = [
                L([(9, 40), (73, 40), (91, 25), (91, 57), (73, 46), (9, 46)]),
                L([(21, 43), (21, 75), (74, 75), (76, 64)]),
                L([(21, 69), (77, 69)]),
                L([(33, 39), (33, 50)])
            ]
            var detail = [L([(65, 40), (65, 51)]), L([(29, 70), (29, 77)])]
            if kind == .altoTrombone { detail.append(L([(48, 47), (48, 62)])) }
            if kind == .bassTrombone { detail.append(L([(49, 48), (49, 65)])) }
            return Self(primary: primary, details: detail, engraving: [])
        case .tuba, .contrabassTuba:
            let primary = [
                L([(31, 18), (74, 18), (82, 8), (83, 27), (75, 27)]),
                L([(31, 18), (31, 75), (39, 86), (66, 86), (73, 75), (73, 28)]),
                O(37, 42, 31, 36),
                L([(41, 27), (41, 65), (51, 70), (57, 64), (57, 28)])
            ]
            var details = [L([(46, 25), (46, 39)]), L([(55, 25), (55, 39)]),
                           L([(64, 25), (64, 39)])]
            if kind == .contrabassTuba {
                details.append(L([(25, 29), (25, 74), (39, 88)]))
                details.append(L([(37, 51), (37, 75)]))
            }
            return Self(primary: primary, details: details,
                        engraving: [L([(36, 50), (36, 74)])])
        case .brassEnsemble:
            return Self(primary: [O(12, 31, 50, 45), O(25, 42, 23, 22),
                                  L([(49, 43), (88, 26), (88, 75), (54, 65)])],
                        details: [L([(21, 30), (16, 19)]), L([(31, 29), (31, 17)])],
                        engraving: [])
        case .violin, .viola, .cello, .doubleBass, .strings:
            // Classic waist silhouette, fingerboard, bridge, f-holes and pegbox.
            var body = Path()
            body.move(to: CGPoint(x: 50, y: 33))
            body.addCurve(to: CGPoint(x: 26, y: 56),
                          control1: CGPoint(x: 14, y: 20), control2: CGPoint(x: 15, y: 48))
            body.addCurve(to: CGPoint(x: 28, y: 72),
                          control1: CGPoint(x: 44, y: 55), control2: CGPoint(x: 16, y: 65))
            body.addCurve(to: CGPoint(x: 72, y: 72),
                          control1: CGPoint(x: 17, y: 101), control2: CGPoint(x: 84, y: 101))
            body.addCurve(to: CGPoint(x: 74, y: 56),
                          control1: CGPoint(x: 84, y: 65), control2: CGPoint(x: 56, y: 55))
            body.addCurve(to: CGPoint(x: 50, y: 33),
                          control1: CGPoint(x: 85, y: 48), control2: CGPoint(x: 86, y: 20))
            body.closeSubpath()
            // Player and section names resolve to their instrument body, but
            // size, scroll and endpin differ between violin, viola, cello and bass.
            let scale: CGFloat
            switch kind {
            case .violin: scale = 0.80
            case .viola: scale = 0.89
            case .cello: scale = 1.0
            case .doubleBass: scale = 1.08
            default: scale = 0.95
            }
            let bodyTransform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: 50 * (1 - scale), ty: 63 * (1 - scale)
            )
            var primary = [
                body.applying(bodyTransform),
                L([(46, 43), (46, 8), (54, 8), (54, 43)]),
                L([(42, 60), (58, 60)]),
                L([(38, 8), (62, 8)]),
                L([(50, 8), (50, 3)])
            ]
            if kind == .violin {
                // A slender bow makes the small solo violin immediately distinct.
                primary.append(L([(82, 18), (91, 85)]))
            }
            if kind == .doubleBass {
                primary.append(L([(38, 33), (29, 25), (27, 19)]))
                primary.append(L([(62, 33), (71, 25), (73, 19)]))
            }
            var detail = [L([(44, 46), (44, 85)]), L([(48, 46), (48, 85)]),
                          L([(52, 46), (52, 85)]), L([(56, 46), (56, 85)]),
                          L([(35, 53), (38, 59), (34, 65)]),
                          L([(65, 53), (62, 59), (66, 65)])]
            if kind == .doubleBass {
                primary.append(L([(50, 88), (50, 100)]))
                detail.append(L([(29, 92), (38, 96), (62, 96), (71, 92)]))
            } else if kind == .cello {
                primary.append(L([(50, 86), (50, 99)]))
            } else if kind == .viola {
                detail.append(L([(32, 47), (36, 42)]))
            } else if kind == .strings {
                detail.append(L([(15, 24), (8, 30), (8, 70), (15, 76)]))
            }
            return Self(primary: primary, details: detail,
                        engraving: [L([(32, 72), (40, 79)]), L([(68, 72), (60, 79)])])
        case .timpani:
            return Self(primary: [
                O(15, 25, 70, 21), L([(15, 36), (28, 72), (39, 80), (61, 80), (72, 72), (85, 36)]),
                L([(30, 79), (24, 92)]), L([(70, 79), (76, 92)])
            ], details: [L([(25, 52), (75, 52)]), L([(43, 79), (43, 88)])],
               engraving: [L([(36, 61), (64, 61)])])
        case .snare, .bassDrum, .percussion:
            return Self(primary: [
                O(18, 23, 64, 22), O(18, 61, 64, 22),
                L([(18, 34), (18, 72)]), L([(82, 34), (82, 72)]),
                L([(26, 80), (22, 91)]), L([(74, 80), (78, 91)])
            ], details: [L([(26, 40), (70, 70)]), L([(70, 40), (26, 70)])],
               engraving: [L([(37, 49), (63, 64)])])
        case .cymbals:
            return Self(primary: [
                O(12, 20, 76, 22), L([(50, 40), (50, 84)]),
                L([(27, 86), (73, 86)])
            ], details: [O(40, 25, 20, 10)], engraving: [])
        case .triangle:
            return Self(primary: [L([(50, 11), (88, 80), (12, 80), (48, 16)])],
                        details: [L([(69, 21), (79, 48)])], engraving: [])
        case .gong:
            return Self(primary: [O(20, 15, 60, 60), L([(18, 8), (82, 8)]),
                                  L([(17, 8), (17, 91)]), L([(83, 8), (83, 91)])],
                        details: [O(37, 32, 26, 26)], engraving: [])
        case .mallets, .xylophone, .vibraphone, .marimba, .bells, .glockenspiel:
            var bars: [Path] = []
            for index in 0..<6 {
                let step = CGFloat(index)
                let x: CGFloat = 12 + step * 13
                let y: CGFloat = 22 + step * 3
                let height: CGFloat = 50 - step * 4
                bars.append(B(x, y, 10, height))
            }
            var base = [L([(10, 78), (88, 78)]), L([(14, 20), (85, 20)])]
            var details: [Path] = [L([(22, 14), (76, 85)])]
            if kind == .marimba {
                base.append(L([(21, 84), (76, 84)]))
                details.append(L([(20, 75), (20, 89)]))
                details.append(L([(31, 75), (31, 93)]))
                details.append(L([(42, 75), (42, 92)]))
                details.append(L([(53, 75), (53, 88)]))
            } else if kind == .vibraphone {
                base.append(L([(10, 90), (91, 90)]))
                details.append(L([(49, 78), (49, 90)]))
                details.append(L([(34, 90), (63, 90)]))
            } else if kind == .glockenspiel || kind == .bells {
                base.append(L([(12, 42), (80, 42)]))
            }
            return Self(primary: base + bars, details: details, engraving: [])
        case .crotales:
            var disks: [Path] = []
            for index in 0..<5 {
                let step = CGFloat(index)
                disks.append(O(10 + step * 16, 20 + step * 8, 17, 17))
            }
            return Self(primary: disks + [L([(12, 75), (91, 75)])],
                        details: [L([(27, 74), (26, 89)]), L([(69, 74), (70, 89)])],
                        engraving: [])
        case .handbells:
            return Self(primary: [
                L([(31, 67), (35, 29), (49, 16), (63, 29), (68, 67), (31, 67)]),
                O(29, 61, 42, 13), L([(49, 16), (49, 8)])
            ], details: [O(45, 72, 10, 10)], engraving: [])
        case .tambourine:
            var jingles: [Path] = []
            let jingleCenters: [(CGFloat, CGFloat)] = [
                (50, 18), (75, 29), (82, 53), (66, 78),
                (36, 78), (18, 55), (26, 28)
            ]
            for center in jingleCenters {
                jingles.append(O(center.0 - 5, center.1 - 5, 10, 10))
            }
            return Self(primary: [O(14, 14, 72, 72), O(23, 23, 54, 54)],
                        details: jingles,
                        engraving: [])
        case .maracas:
            return Self(primary: [
                O(16, 8, 28, 37), O(56, 15, 28, 37),
                L([(34, 45), (64, 91)]), L([(68, 52), (40, 93)])
            ], details: [L([(23, 24), (32, 32)]), L([(66, 28), (74, 35)])],
               engraving: [])
        case .castanets:
            return Self(primary: [
                L([(16, 70), (13, 44), (28, 22), (48, 44), (48, 73), (16, 70)]),
                L([(52, 70), (52, 41), (70, 20), (87, 44), (84, 74), (52, 70)])
            ], details: [L([(22, 62), (39, 62)]), L([(61, 62), (78, 62)])],
               engraving: [])
        case .woodblock:
            return Self(primary: [
                B(14, 31, 62, 42), L([(78, 31), (87, 17)]),
                L([(74, 67), (88, 78)]), L([(60, 18), (86, 8)])
            ], details: [L([(23, 42), (67, 42)]), L([(29, 58), (61, 58)])],
               engraving: [])
        case .windMachine:
            return Self(primary: [
                O(19, 17, 58, 58), L([(49, 17), (49, 75)]),
                L([(20, 46), (78, 46)]),
                L([(16, 82), (16, 89), (88, 89), (88, 82)])
            ], details: [L([(27, 25), (72, 68)]), L([(29, 68), (69, 25)])],
               engraving: [])
        case .chimes:
            var pipes: [Path] = []
            for index in 0..<6 {
                let step = CGFloat(index)
                let x: CGFloat = 19 + step * 12
                let bottom: CGFloat = 88 - step * 5
                pipes.append(L([(x, 28), (x, bottom)]))
            }
            return Self(primary: [L([(10, 18), (90, 18)]),
                                  L([(10, 18), (10, 92)]), L([(90, 18), (90, 92)])] + pipes,
                        details: [L([(20, 11), (20, 24)])], engraving: [])
        case .harp:
            let frame = [
                L([(27, 91), (30, 18), (51, 8), (76, 30), (78, 88), (27, 91)]),
                L([(32, 29), (75, 31)]),
                L([(29, 87), (74, 87)])
            ]
            var strings: [Path] = []
            for index in 0..<7 {
                let x: CGFloat = 37 + CGFloat(index) * 5
                strings.append(L([(x, 31), (x + 3, 84)]))
            }
            return Self(primary: frame, details: strings, engraving: [])
        case .piano:
            return Self(primary: [
                line([(14, 37), (28, 14), (76, 14), (86, 33), (75, 59), (14, 59)], closed: true),
                L([(24, 60), (20, 90)]), L([(73, 60), (82, 90)]),
                L([(14, 59), (75, 59)])
            ], details: [L([(19, 48), (66, 48)]), L([(24, 52), (24, 59)]),
                         L([(36, 52), (36, 59)]), L([(48, 52), (48, 59)])],
               engraving: [L([(36, 26), (73, 26)])])
        case .celesta, .harpsichord:
            let primary = [B(12, 30, 76, 45), L([(20, 75), (16, 91)]),
                           L([(80, 75), (84, 91)]), L([(18, 49), (82, 49)])]
            var keys: [Path] = []
            for index in 0..<9 {
                let x: CGFloat = 20 + CGFloat(index) * 7
                keys.append(L([(x, 50), (x, 69)]))
            }
            return Self(primary: primary, details: keys,
                        engraving: [L([(15, 36), (82, 36)])])
        case .organ:
            var pipes: [Path] = []
            for index in 0..<5 {
                let x: CGFloat = 16 + CGFloat(index) * 14
                let rise = CGFloat(abs(2 - index))
                let y: CGFloat = 15 + rise * 6
                let height: CGFloat = 51 - rise * 6
                pipes.append(B(x, y, 10, height))
            }
            return Self(primary: pipes + [B(12, 68, 76, 20)],
                        details: [L([(20, 76), (81, 76)]),
                                  L([(27, 76), (27, 85)]), L([(40, 76), (40, 85)]),
                                  L([(53, 76), (53, 85)]), L([(66, 76), (66, 85)])],
                        engraving: [])
        case .glassArmonica:
            return Self(primary: [L([(15, 84), (86, 84)]),
                                  L([(20, 31), (74, 31)]),
                                  O(25, 30, 49, 42)],
                        details: [O(35, 37, 29, 29), O(43, 42, 14, 19)],
                        engraving: [])
        case .choir:
            return Self(primary: [
                O(39, 12, 22, 22),
                O(9, 27, 19, 19),
                O(72, 27, 19, 19),
                L([(23, 85), (23, 61), (32, 48), (44, 44), (56, 44), (68, 48), (77, 61), (77, 85)]),
                L([(9, 83), (9, 62), (22, 54)]),
                L([(91, 83), (91, 62), (78, 54)])
            ], details: [L([(27, 85), (73, 85)])], engraving: [])
        case .synth:
            var keys: [Path] = []
            for index in 0..<8 {
                let x: CGFloat = 18 + CGFloat(index) * 9
                keys.append(L([(x, 49), (x, 77)]))
            }
            return Self(primary: [B(9, 22, 82, 60), L([(15, 48), (85, 48)])],
                        details: keys + [O(22, 30, 8, 8), O(37, 30, 8, 8),
                                        L([(56, 35), (81, 35)])], engraving: [])
        case .wind:
            return Self(primary: [L([(10, 33), (68, 33)]),
                                  L([(19, 49), (83, 49)]),
                                  L([(8, 66), (70, 66)])],
                        details: [O(62, 27, 18, 13), O(65, 60, 23, 17)],
                        engraving: [])
        case .world:
            return Self(primary: [O(18, 18, 64, 64), L([(18, 50), (82, 50)]),
                                  L([(50, 18), (50, 82)])],
                        details: [O(31, 18, 38, 64)], engraving: [])
        case .orchestra:
            return Self(primary: [L([(13, 80), (13, 38), (25, 22), (75, 22), (87, 38), (87, 80)]),
                                  O(25, 45, 14, 14), O(44, 37, 14, 14), O(63, 45, 14, 14)],
                        details: [L([(23, 66), (76, 66)])], engraving: [])
        case .generic:
            return Self(primary: [O(18, 14, 64, 64), L([(62, 23), (62, 68)]),
                                  L([(62, 23), (79, 18)]), O(36, 65, 25, 16)],
                        details: [], engraving: [])
        }
    }
}
