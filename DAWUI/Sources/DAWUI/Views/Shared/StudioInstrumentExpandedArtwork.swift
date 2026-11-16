import SwiftUI

// MARK: - Expanded Native Instrument Artwork
//
// Isolated from the core renderer to keep the original orchestral silhouettes
// stable. Every drawing is local vector geometry, used for track icons and
// browser previews; none of this changes Garritan patch loading or playback.

extension InstrumentIconDrawing {
    static func makeExpandedInstrument(_ kind: InstrumentIconIdentity) -> Self? {
        let L: ([(CGFloat, CGFloat)]) -> Path = { line($0) }
        let O = oval
        let B = box

        switch kind {
        case .marchingBassDrum:
            return Self(
                primary: [
                    O(14, 16, 72, 72), O(22, 24, 56, 56),
                    L([(35, 12), (45, 4), (55, 4), (65, 12)]),
                    L([(20, 47), (9, 60), (9, 81)]),
                    L([(80, 47), (91, 60), (91, 81)])
                ],
                details: [L([(34, 18), (34, 82)]), L([(66, 18), (66, 82)])],
                engraving: [],
                silhouettes: [O(23, 25, 54, 54)]
            )
        case .splashCymbal:
            return Self(
                primary: [
                    O(22, 35, 56, 13), O(45, 31, 12, 7),
                    L([(50, 47), (50, 85)]), L([(31, 85), (70, 85)])
                ],
                details: [L([(28, 40), (72, 40)])],
                engraving: [],
                silhouettes: [O(23, 36, 54, 11)]
            )
        case .chinaCymbal:
            return Self(
                primary: [
                    L([(10, 30), (22, 26), (30, 41), (42, 47), (58, 47),
                       (70, 41), (78, 26), (90, 30)]),
                    L([(10, 36), (25, 33), (36, 53), (64, 53), (75, 33), (90, 36)]),
                    L([(50, 53), (50, 85)]), L([(25, 86), (75, 86)])
                ],
                details: [O(44, 40, 12, 10)],
                engraving: []
            )
        case .thunderSheet:
            return Self(
                primary: [
                    L([(20, 18), (80, 18), (80, 85), (20, 85), (20, 18)]),
                    L([(50, 18), (50, 5)]), O(46, 4, 8, 8)
                ],
                details: [
                    L([(28, 31), (37, 41), (30, 50), (44, 63), (36, 75)]),
                    L([(59, 29), (71, 42), (59, 57), (68, 70)])
                ],
                engraving: [],
                silhouettes: [B(20, 18, 60, 67)]
            )
        case .rainstick:
            return Self(
                primary: [
                    L([(24, 87), (73, 12), (83, 19), (34, 94), (24, 87)]),
                    L([(73, 12), (67, 7), (78, 1), (83, 19)])
                ],
                details: [
                    O(37, 71, 4, 4), O(47, 57, 4, 4),
                    O(55, 47, 4, 4), O(65, 32, 4, 4)
                ],
                engraving: [],
                silhouettes: [line([(24, 87), (73, 12), (83, 19), (34, 94)], closed: true)]
            )
        case .bongos:
            return Self(
                primary: [
                    O(9, 22, 40, 21), O(51, 27, 40, 21),
                    L([(9, 32), (15, 75), (43, 75), (49, 32)]),
                    L([(51, 38), (58, 82), (85, 82), (91, 38)])
                ],
                details: [L([(24, 46), (25, 71)]), L([(72, 50), (73, 77)])],
                engraving: [],
                silhouettes: [O(10, 23, 38, 19), O(52, 28, 38, 19)]
            )
        case .congas:
            return Self(
                primary: [
                    O(9, 14, 38, 18), O(53, 18, 38, 18),
                    L([(9, 22), (13, 66), (19, 84), (39, 84), (44, 65), (47, 22)]),
                    L([(53, 27), (57, 69), (63, 89), (81, 89), (86, 70), (91, 27)])
                ],
                details: [
                    L([(18, 40), (19, 69)]), L([(36, 40), (36, 69)]),
                    L([(64, 45), (64, 72)]), L([(81, 45), (81, 72)])
                ],
                engraving: [],
                silhouettes: [O(10, 15, 36, 16), O(54, 19, 36, 16)]
            )
        case .djembe:
            return Self(
                primary: [
                    O(18, 13, 64, 22),
                    L([(18, 25), (32, 55), (42, 68), (33, 87),
                       (67, 87), (58, 68), (68, 55), (82, 25)])
                ],
                details: [
                    L([(25, 34), (72, 59)]), L([(75, 34), (29, 59)]),
                    L([(32, 55), (68, 55)])
                ],
                engraving: [],
                silhouettes: [O(19, 14, 62, 20)]
            )
        case .tabla:
            return Self(
                primary: [
                    O(8, 25, 42, 19), O(52, 19, 40, 22),
                    L([(8, 34), (13, 75), (44, 75), (50, 34)]),
                    L([(52, 30), (55, 75), (86, 75), (92, 30)]),
                    O(23, 31, 13, 9), O(65, 25, 14, 10)
                ],
                details: [L([(19, 45), (22, 70)]), L([(76, 43), (78, 71)])],
                engraving: [],
                silhouettes: [O(9, 26, 40, 17), O(53, 20, 38, 20)]
            )
        case .taiko:
            return Self(
                primary: [
                    O(20, 20, 60, 62), O(30, 29, 40, 44),
                    L([(20, 40), (8, 59), (9, 84)]),
                    L([(80, 40), (92, 59), (91, 84)]),
                    L([(35, 80), (28, 94)]), L([(65, 80), (72, 94)])
                ],
                details: [
                    O(26, 26, 48, 50), L([(27, 48), (73, 48)])
                ],
                engraving: [],
                silhouettes: [O(21, 21, 58, 60)]
            )

        case .guitar, .acousticGuitar, .classicalGuitar, .electricGuitar, .electricBass,
             .banjo, .mandolin, .ukulele:
            return makePluckedInstrument(kind)
        case .uprightBass:
            let base = make(.doubleBass)
            return Self(
                primary: base.primary + [L([(26, 85), (15, 92)])],
                details: base.details + [L([(62, 87), (75, 95)])],
                engraving: base.engraving,
                silhouettes: base.silhouettes
            )

        case .uprightPiano:
            return Self(
                primary: [
                    B(15, 10, 70, 77), L([(16, 55), (84, 55)]),
                    L([(21, 87), (21, 97)]), L([(79, 87), (79, 97)])
                ],
                details: keyboardKeys(x: 21, y: 59, count: 9, spacing: 7),
                engraving: [L([(19, 30), (81, 30)])],
                silhouettes: [B(16, 11, 68, 75)]
            )
        case .electricPiano:
            return Self(
                primary: [
                    B(8, 25, 84, 44), L([(12, 40), (88, 40)]),
                    L([(17, 69), (12, 91)]), L([(83, 69), (88, 91)]),
                    L([(12, 91), (28, 91)]), L([(72, 91), (88, 91)])
                ],
                details: keyboardKeys(x: 16, y: 46, count: 10, spacing: 7) +
                    [O(17, 29, 6, 6), O(30, 29, 6, 6)],
                engraving: [],
                silhouettes: [B(9, 26, 82, 42)]
            )
        case .clavinet:
            return Self(
                primary: [
                    B(8, 20, 84, 60), L([(8, 48), (92, 48)]),
                    L([(14, 25), (86, 25)])
                ],
                details: keyboardKeys(x: 15, y: 53, count: 10, spacing: 7) +
                    [L([(22, 34), (76, 34)]), O(79, 29, 7, 7)],
                engraving: [],
                silhouettes: [B(9, 21, 82, 58)]
            )
        case .accordion:
            var bellows: [Path] = []
            for i in 0..<6 {
                let x = CGFloat(29 + i * 8)
                bellows.append(L([(x, 20), (x - 3, 51), (x, 79)]))
            }
            return Self(
                primary: [B(7, 16, 22, 68), B(71, 16, 22, 68), L([(29, 20), (71, 20)]),
                          L([(29, 80), (71, 80)])] + bellows,
                details: [
                    O(14, 28, 5, 5), O(20, 39, 5, 5), O(14, 50, 5, 5),
                    L([(80, 24), (80, 75)]), L([(87, 24), (87, 75)])
                ],
                engraving: [],
                silhouettes: [B(8, 17, 20, 66), B(72, 17, 20, 66)]
            )

        case .sitar:
            return Self(
                primary: [
                    O(13, 62, 48, 32),
                    L([(42, 69), (70, 10)]), L([(49, 69), (78, 10)]),
                    L([(70, 10), (82, 4), (86, 10), (78, 18)])
                ],
                details: [
                    O(29, 72, 16, 14),
                    L([(50, 50), (71, 50)]),
                    L([(56, 37), (74, 37)]),
                    L([(64, 24), (80, 24)])
                ],
                engraving: [],
                silhouettes: [O(14, 63, 46, 30)]
            )
        case .oud:
            return Self(
                primary: [
                    L([(57, 58), (72, 20), (81, 11), (89, 15)]),
                    O(12, 38, 55, 53),
                    L([(45, 70), (74, 17)])
                ],
                details: [O(32, 57, 17, 18), O(26, 78, 8, 6),
                          L([(48, 43), (66, 44)])],
                engraving: [],
                silhouettes: [O(13, 39, 53, 51)]
            )
        case .erhu:
            return Self(
                primary: [
                    B(37, 69, 26, 20), L([(47, 69), (47, 13)]),
                    L([(54, 69), (54, 13)]),
                    L([(45, 14), (30, 8)]), L([(54, 19), (71, 12)]),
                    L([(22, 88), (78, 27)])
                ],
                details: [L([(50, 16), (50, 70)]), L([(41, 76), (59, 76)])],
                engraving: [],
                silhouettes: [B(38, 70, 24, 18)]
            )
        case .koto:
            let bridges: [Path] = (0..<7).map { i in
                let x = CGFloat(19 + i * 10)
                return L([(x, 62), (x + 4, 52), (x + 8, 62)])
            }
            return Self(
                primary: [
                    L([(8, 43), (92, 35), (92, 76), (8, 84), (8, 43)]),
                    L([(12, 49), (88, 42)]), L([(12, 73), (88, 66)])
                ],
                details: bridges,
                engraving: [],
                silhouettes: [line([(8, 43), (92, 35), (92, 76), (8, 84)], closed: true)]
            )
        case .shakuhachi:
            return Self(
                primary: [
                    L([(24, 84), (71, 16)]), L([(33, 91), (80, 23)]),
                    L([(24, 84), (33, 91)]), L([(71, 16), (80, 23)])
                ],
                details: [
                    O(41, 65, 5, 5), O(50, 52, 5, 5),
                    O(59, 39, 5, 5), O(68, 26, 5, 5)
                ],
                engraving: [],
                silhouettes: [line([(24, 84), (71, 16), (80, 23), (33, 91)], closed: true)]
            )
        case .panFlute:
            var tubes: [Path] = []
            for i in 0..<8 {
                let x = CGFloat(10 + i * 10)
                let y = CGFloat(22 + i * 5)
                tubes.append(B(x, y, 9, 75 - y))
            }
            return Self(
                primary: tubes + [L([(10, 52), (89, 52)])],
                details: [L([(12, 58), (86, 58)])],
                engraving: [],
                silhouettes: tubes
            )

        default:
            return nil
        }
    }

    private static func keyboardKeys(x: CGFloat, y: CGFloat,
                                     count: Int, spacing: CGFloat) -> [Path] {
        (0..<count).map { index in
            let px = x + CGFloat(index) * spacing
            return line([(px, y), (px, y + 24)])
        }
    }

    private static func makePluckedInstrument(_ kind: InstrumentIconIdentity) -> Self {
        let L: ([(CGFloat, CGFloat)]) -> Path = { line($0) }
        let O = oval
        let electric = kind == .electricGuitar || kind == .electricBass
        let bass = kind == .electricBass
        let short = kind == .ukulele || kind == .mandolin || kind == .banjo
        let neckTop: CGFloat = bass ? 5 : (short ? 22 : 11)

        let body: Path
        if kind == .banjo {
            body = O(13, 48, 61, 44)
        } else if kind == .mandolin {
            body = O(15, 45, 57, 47)
        } else if electric {
            body = L([(28, 58), (16, 49), (14, 66), (20, 87),
                      (46, 95), (64, 84), (69, 65), (58, 51), (46, 65), (28, 58)])
        } else {
            body = L([(45, 48), (31, 43), (16, 52), (15, 69),
                      (23, 91), (51, 95), (67, 79), (67, 60),
                      (58, 49), (48, 53), (45, 48)])
        }

        var primary = [
            body, L([(44, 60), (64, neckTop)]),
            L([(53, 64), (73, neckTop + 4)]),
            L([(64, neckTop), (73, neckTop + 4)]),
            L([(69, neckTop + 2), (84, neckTop - 2)])
        ]
        if kind == .classicalGuitar {
            primary.append(O(32, 64, 16, 16))
        } else if kind == .acousticGuitar || kind == .guitar || kind == .ukulele {
            primary.append(O(33, 64, 14, 14))
        } else if electric {
            primary.append(L([(34, 69), (49, 72)]))
            primary.append(L([(31, 77), (48, 80)]))
        } else if kind == .banjo {
            primary.append(O(20, 55, 46, 31))
        } else if kind == .mandolin {
            primary.append(O(35, 62, 10, 11))
        }
        let frets: [Path] = (0..<5).map { index in
            let y = neckTop + 8 + CGFloat(index) * 7
            let x = 65 - CGFloat(index) * 3
            return L([(x, y), (x + 8, y + 3)])
        }
        return Self(
            primary: primary,
            details: frets + [L([(27, 84), (46, 88)])],
            engraving: [],
            silhouettes: [body]
        )
    }
}
