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
        let kind = InstrumentIconIdentity.resolve(name: name, path: path, category: category)
        let art = InstrumentIconDrawing.make(kind)
        Canvas { graphicContext, bounds in
            var context = graphicContext
            context.scaleBy(x: bounds.width / 100, y: bounds.height / 100)

            let style = collection
            let ink: Color
            let detailInk: Color
            let width: CGFloat

            switch style {
            case .heritageEtching:
                ink = palette.accent
                detailInk = palette.secondaryText.opacity(0.85)
                width = 3.7
            case .elegantMonoline, .matchAppearance:
                ink = palette.primaryText
                detailInk = palette.secondaryText
                width = 4.8
            case .gpo5Signature:
                ink = palette.primaryText
                detailInk = palette.accent
                width = 6.4
            case .concertMedallion:
                ink = Color(red: 0.93, green: 0.76, blue: 0.48)
                detailInk = Color(red: 0.97, green: 0.87, blue: 0.66)
                width = 5.4
                let coin = Path(ellipseIn: CGRect(x: 3, y: 3, width: 94, height: 94))
                context.fill(coin, with: .color(Color(red: 0.10, green: 0.15, blue: 0.18)))
                context.stroke(coin, with: .color(ink), lineWidth: 3.4)
                context.stroke(
                    Path(ellipseIn: CGRect(x: 9, y: 9, width: 82, height: 82)),
                    with: .color(ink.opacity(0.55)), lineWidth: 1.5
                )
                context.translateBy(x: 16, y: 16)
                context.scaleBy(x: 0.68, y: 0.68)
            }

            let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            let detail = StrokeStyle(
                lineWidth: style == .heritageEtching ? 2.0 : 2.6,
                lineCap: .round, lineJoin: .round
            )
            for shape in art.primary {
                context.stroke(shape, with: .color(ink), style: stroke)
            }
            for shape in art.details {
                context.stroke(shape, with: .color(detailInk), style: detail)
            }
            if style == .heritageEtching {
                // Light engraved shading differentiates the heritage collection.
                for shape in art.engraving {
                    context.stroke(
                        shape, with: .color(detailInk.opacity(0.60)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                }
            }
        }
        .frame(width: dimension, height: dimension)
        .accessibilityLabel(kind.accessibilityLabel)
        .accessibilityHidden(false)
    }
}

private enum InstrumentIconIdentity: Equatable {
    case piccolo, flute, altoFlute, bassFlute, oboe, englishHorn, clarinet, bassClarinet
    case contrabassClarinet, bassoon, contrabassoon
    case horn, trumpet, trombone, bassTrombone, tuba, brassEnsemble
    case violin, viola, cello, doubleBass, strings
    case timpani, snare, bassDrum, cymbals, triangle, gong, mallets, chimes, bells
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
        case .trombone: return "Trombone"
        case .bassTrombone: return "Bass trombone"
        case .tuba: return "Tuba"
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
        if has(["trombone"]) { return .trombone }
        if has(["piccolo trumpet", "trumpet", "cornet"]) { return .trumpet }
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
        if has(["glockenspiel", "handbell", "crotale", "bell"]) { return .bells }
        if has(["xylophone", "vibraphone", "marimba"]) { return .mallets }
        if has(["percussion", "tambourine", "drum", "shaker", "castanet", "clave"]) {
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
        if has(["wind machine"]) { return .wind }
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
            let detail = (0..<5).map { i in O(CGFloat(48+i), CGFloat(31+i*9), 4, 4) }
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
            let detail = (0..<5).map { i in O(CGFloat(43+i*2), CGFloat(24+i*10), 5, 5) }
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
        case .trumpet:
            let primary = [
                L([(8, 55), (73, 48), (91, 35), (91, 71), (73, 56), (8, 62)]),
                L([(18, 45), (18, 68)]), L([(18, 45), (64, 43), (64, 66), (18, 68)])
            ]
            let detail = [
                L([(38, 42), (38, 23), (45, 23), (45, 42)]),
                L([(49, 42), (49, 23), (56, 23), (56, 42)]),
                L([(59, 43), (59, 28), (66, 28), (66, 43)])
            ]
            return Self(primary: primary, details: detail, engraving: [L([(26, 57), (68, 51)])])
        case .trombone, .bassTrombone:
            let primary = [
                L([(9, 40), (73, 40), (91, 25), (91, 57), (73, 46), (9, 46)]),
                L([(21, 43), (21, 75), (74, 75), (76, 64)]),
                L([(21, 69), (77, 69)]),
                L([(33, 39), (33, 50)])
            ]
            return Self(primary: primary,
                        details: [L([(65, 40), (65, 51)]), L([(29, 70), (29, 77)])],
                        engraving: kind == .bassTrombone ? [L([(49, 48), (49, 65)])] : [])
        case .tuba:
            let primary = [
                L([(31, 18), (74, 18), (82, 8), (83, 27), (75, 27)]),
                L([(31, 18), (31, 75), (39, 86), (66, 86), (73, 75), (73, 28)]),
                O(37, 42, 31, 36),
                L([(41, 27), (41, 65), (51, 70), (57, 64), (57, 28)])
            ]
            return Self(primary: primary,
                        details: [L([(46, 25), (46, 39)]), L([(55, 25), (55, 39)]),
                                  L([(64, 25), (64, 39)])],
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
            let primary = [
                body, L([(46, 43), (46, 8), (54, 8), (54, 43)]),
                L([(42, 60), (58, 60)]), L([(38, 8), (62, 8)]),
                L([(50, 8), (50, 3)])
            ]
            var detail = [L([(44, 46), (44, 85)]), L([(48, 46), (48, 85)]),
                          L([(52, 46), (52, 85)]), L([(56, 46), (56, 85)]),
                          L([(35, 53), (38, 59), (34, 65)]),
                          L([(65, 53), (62, 59), (66, 65)])]
            if kind == .doubleBass {
                detail.append(L([(29, 92), (38, 96), (62, 96), (71, 92)]))
            } else if kind == .cello {
                detail.append(L([(50, 86), (50, 98)]))
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
        case .mallets, .bells:
            let bars = (0..<6).map { i in
                B(CGFloat(12+i*13), CGFloat(22+i*3), 10, CGFloat(50-i*4))
            }
            return Self(primary: [L([(10, 78), (88, 78)]), L([(14, 20), (85, 20)])] + bars,
                        details: [L([(22, 14), (76, 85)])], engraving: [])
        case .chimes:
            let pipes = (0..<6).map { i in
                L([(CGFloat(19+i*12), 28), (CGFloat(19+i*12), CGFloat(88-i*5))])
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
            let strings = (0..<7).map { i in
                let x = CGFloat(37+i*5)
                return L([(x, 31), (x+3, 84)])
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
            let keys = (0..<9).map { i in
                L([(CGFloat(20+i*7), 50), (CGFloat(20+i*7), 69)])
            }
            return Self(primary: primary, details: keys,
                        engraving: [L([(15, 36), (82, 36)])])
        case .organ:
            let pipes = (0..<5).map { i in
                B(CGFloat(16+i*14), CGFloat(15+abs(2-i)*6), 10,
                  CGFloat(51-abs(2-i)*6))
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
            let keys = (0..<8).map { i in
                L([(CGFloat(18+i*9), 49), (CGFloat(18+i*9), 77)])
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
