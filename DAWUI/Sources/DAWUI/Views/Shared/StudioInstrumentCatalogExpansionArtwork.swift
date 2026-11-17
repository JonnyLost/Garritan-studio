import SwiftUI

// MARK: - Garritan catalog expansion — native silhouette sketches
//
// These are original local SwiftUI vectors for the published Garritan Jazz &
// Big Band, Concert & Marching Band, and World Instruments families. They are
// not samples, plugins, downloaded artwork or final anatomical illustrations.
// Keep this layer separate from the existing tested orchestra icon geometry.

extension InstrumentIconDrawing {
    static func makeCatalogExpansion(_ kind: InstrumentIconIdentity) -> Self? {
        let L: ([(CGFloat, CGFloat)]) -> Path = { line($0) }
        let O = oval
        let B = box

        switch kind {
        case .sopraninoSaxophone, .mezzoSopranoSaxophone,
             .curvedSopranoSaxophone, .cMelodySaxophone,
             .contrabassSaxophone, .subcontrabassSaxophone:
            let baseIdentity: InstrumentIconIdentity
            let scale: CGFloat
            switch kind {
            case .sopraninoSaxophone: baseIdentity = .sopranoSaxophone; scale = 0.77
            case .mezzoSopranoSaxophone: baseIdentity = .sopranoSaxophone; scale = 0.92
            case .curvedSopranoSaxophone: baseIdentity = .altoSaxophone; scale = 0.84
            case .cMelodySaxophone: baseIdentity = .tenorSaxophone; scale = 0.88
            case .contrabassSaxophone: baseIdentity = .bassSaxophone; scale = 0.96
            case .subcontrabassSaxophone: baseIdentity = .bassSaxophone; scale = 0.89
            default: return nil
            }
            let base = make(baseIdentity)
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: 50 * (1 - scale), ty: 50 * (1 - scale)
            )
            var primary = base.primary.map { $0.applying(transform) }
            let details = base.details.map { $0.applying(transform) }
            let silhouettes = base.silhouettes.map { $0.applying(transform) }
            switch kind {
            case .sopraninoSaxophone:
                primary.append(L([(72, 75), (83, 73)]))
            case .mezzoSopranoSaxophone:
                primary.append(L([(70, 82), (79, 86), (89, 75)]))
            case .curvedSopranoSaxophone:
                primary.append(L([(65, 82), (83, 93), (93, 76)]))
            case .cMelodySaxophone:
                primary.append(L([(59, 75), (77, 82), (90, 72)]))
            case .contrabassSaxophone:
                primary.append(L([(25, 32), (15, 40), (15, 63), (32, 72)]))
            case .subcontrabassSaxophone:
                primary += [
                    L([(26, 30), (15, 32), (10, 49), (20, 63)]),
                    L([(20, 63), (13, 73), (28, 88), (47, 82)])
                ]
            default: break
            }
            return Self(primary: primary, details: details,
                        engraving: [], silhouettes: silhouettes)

        case .mellophone:
            return Self(
                primary: [
                    L([(14, 54), (63, 52), (81, 35), (93, 26),
                       (93, 77), (81, 67), (63, 56), (14, 62)]),
                    L([(24, 50), (24, 67), (55, 67), (55, 47)]),
                    O(24, 36, 22, 18)
                ],
                details: [
                    L([(38, 48), (38, 30), (45, 30), (45, 48)]),
                    L([(49, 48), (49, 33), (56, 33), (56, 48)])
                ],
                engraving: [],
                silhouettes: [line([(70, 48), (90, 27), (92, 76), (70, 60)], closed: true)]
            )
        case .tenorHorn:
            return Self(
                primary: [
                    O(16, 37, 56, 48),
                    L([(34, 45), (34, 17), (74, 17), (89, 7),
                       (92, 35), (75, 31), (75, 75), (61, 86)]),
                    L([(28, 61), (60, 61), (60, 24)])
                ],
                details: [
                    L([(41, 36), (41, 24)]), L([(50, 36), (50, 22)]),
                    L([(59, 36), (59, 24)])
                ],
                engraving: [],
                silhouettes: [O(18, 39, 52, 45)]
            )
        case .sousaphone:
            return Self(
                primary: [
                    O(13, 23, 65, 68), O(27, 37, 35, 40),
                    L([(40, 23), (58, 12), (76, 12)]),
                    O(66, 3, 30, 28),
                    L([(72, 28), (70, 40), (58, 50)]),
                    L([(21, 65), (10, 85)])
                ],
                details: [
                    L([(37, 67), (48, 67)]), L([(41, 57), (41, 80)])
                ],
                engraving: [],
                silhouettes: [O(14, 24, 63, 66), O(67, 4, 28, 26)]
            )
        case .helicon:
            return Self(
                primary: [
                    O(11, 25, 71, 65), O(27, 43, 39, 32),
                    L([(51, 30), (65, 17), (78, 18), (83, 7)]),
                    O(76, 1, 20, 20),
                    L([(21, 74), (16, 91)])
                ],
                details: [L([(41, 53), (42, 78)]), L([(50, 54), (51, 76)])],
                engraving: [],
                silhouettes: [O(12, 26, 69, 63)]
            )
        case .bansuri:
            var toneHoles: [Path] = []
            for index in 0..<6 {
                let x = CGFloat(30 + index * 9)
                let y = CGFloat(70 - index * 7)
                toneHoles.append(O(x, y, 5, 5))
            }
            return Self(
                primary: [
                    L([(9, 84), (84, 22)]), L([(14, 91), (89, 29)]),
                    L([(9, 84), (14, 91)]), L([(84, 22), (89, 29)])
                ],
                details: toneHoles,
                engraving: [],
                silhouettes: [line([(9, 84), (84, 22), (89, 29), (14, 91)], closed: true)]
            )
        case .duduk:
            let holes = (0..<7).map { i in
                O(44 + CGFloat(i) * 2, 27 + CGFloat(i) * 8, 4, 4)
            }
            return Self(
                primary: [
                    L([(44, 18), (56, 18), (65, 87), (35, 87), (44, 18)]),
                    L([(46, 18), (46, 5), (54, 5), (54, 18)])
                ],
                details: holes,
                engraving: [],
                silhouettes: [line([(44, 18), (56, 18), (65, 87), (35, 87)], closed: true)]
            )
        case .didgeridoo:
            return Self(
                primary: [
                    L([(16, 12), (29, 17), (65, 70), (89, 84)]),
                    L([(10, 21), (23, 27), (57, 82), (82, 95)]),
                    L([(16, 12), (10, 21)]), L([(89, 84), (82, 95)])
                ],
                details: [
                    L([(31, 31), (25, 41)]),
                    L([(47, 53), (40, 64)]),
                    L([(60, 74), (53, 85)])
                ],
                engraving: [],
                silhouettes: [line([(16, 12), (29, 17), (89, 84), (82, 95), (10, 21)], closed: true)]
            )
        case .bagpipes:
            return Self(
                primary: [
                    O(18, 35, 55, 51),
                    L([(30, 40), (19, 6)]), L([(43, 36), (41, 4)]),
                    L([(56, 38), (65, 5)]),
                    L([(66, 73), (83, 94)]),
                    L([(59, 45), (86, 41)])
                ],
                details: [
                    L([(26, 12), (24, 2)]), L([(42, 10), (44, 2)]),
                    L([(63, 11), (66, 2)])
                ],
                engraving: [],
                silhouettes: [O(19, 36, 53, 49)]
            )
        case .mbira:
            var tines: [Path] = []
            for i in 0..<9 {
                let x = CGFloat(19 + i * 7)
                let length = CGFloat(24 + (4 - abs(i - 4)) * 6)
                tines.append(L([(x, 32), (x, 32 + length)]))
            }
            return Self(
                primary: [
                    L([(9, 26), (91, 26), (84, 89), (16, 89), (9, 26)]),
                    L([(16, 49), (84, 49)])
                ],
                details: tines,
                engraving: [],
                silhouettes: [line([(9, 26), (91, 26), (84, 89), (16, 89)], closed: true)]
            )
        case .harmonica:
            var holes: [Path] = []
            for i in 0..<9 {
                holes.append(B(CGFloat(10 + i * 9), 40, 7, 18))
            }
            return Self(
                primary: [B(5, 29, 90, 38), L([(5, 39), (95, 39)])],
                details: holes,
                engraving: [],
                silhouettes: [B(6, 30, 88, 36)]
            )
        case .timbales:
            return Self(
                primary: [
                    O(10, 27, 39, 17), O(52, 22, 39, 17),
                    L([(10, 35), (12, 63), (48, 63), (49, 35)]),
                    L([(52, 30), (54, 60), (89, 60), (91, 30)]),
                    L([(50, 62), (50, 89)]), L([(29, 91), (71, 91)])
                ],
                details: [L([(23, 45), (24, 59)]), L([(75, 42), (76, 56)])],
                engraving: [],
                silhouettes: [O(11, 28, 37, 15), O(53, 23, 37, 15)]
            )
        case .rotoToms:
            return Self(
                primary: [
                    O(5, 35, 27, 20), O(36, 21, 28, 22),
                    O(67, 36, 28, 20),
                    L([(19, 56), (19, 70)]),
                    L([(50, 43), (50, 70)]),
                    L([(81, 56), (81, 70)]),
                    L([(19, 70), (81, 70)]),
                    L([(50, 70), (50, 91)]), L([(30, 93), (70, 93)])
                ],
                details: [L([(12, 43), (26, 43)]), L([(43, 30), (57, 30)])],
                engraving: [],
                silhouettes: [O(6, 36, 25, 18), O(37, 22, 26, 20), O(68, 37, 26, 18)]
            )
        case .flexatone:
            return Self(
                primary: [
                    L([(48, 14), (48, 76)]), L([(56, 14), (56, 76)]),
                    L([(31, 29), (72, 29)]),
                    L([(34, 36), (34, 60), (70, 60), (70, 36)]),
                    L([(51, 76), (51, 93)])
                ],
                details: [
                    O(22, 37, 13, 13), O(69, 37, 13, 13),
                    L([(28, 44), (33, 48)]), L([(72, 44), (77, 48)])
                ],
                engraving: [],
                silhouettes: [line([(34, 36), (70, 36), (70, 60), (34, 60)], closed: true)]
            )
        case .recorder:
            let body: [Path] = [
                L([(32, 13), (44, 9), (67, 89), (55, 93), (32, 13)]),
                L([(32, 13), (25, 15), (27, 32), (36, 32)]),
                L([(39, 11), (45, 31)])
            ]
            var holes: [Path] = []
            for index in 0..<6 {
                let x = CGFloat(41 + index * 3)
                let y = CGFloat(34 + index * 9)
                holes.append(O(x, y, 5, 5))
            }
            let silhouette = line([(32, 13), (44, 9), (67, 89), (55, 93)], closed: true)
            return Self(primary: body, details: holes, engraving: [], silhouettes: [silhouette])
        case .sarrusophone:
            let body: [Path] = [
                L([(33, 18), (41, 20), (61, 69), (76, 82)]),
                L([(41, 19), (48, 17), (70, 68), (80, 80)]),
                L([(76, 82), (90, 65), (93, 81), (76, 94), (61, 80)]),
                L([(34, 17), (30, 4), (38, 3)])
            ]
            var keys: [Path] = []
            for index in 0..<6 {
                let x = CGFloat(44 + index * 3)
                let y = CGFloat(31 + index * 8)
                keys.append(O(x, y, 4, 4))
            }
            let bell = line(
                [(34, 18), (41, 20), (70, 68), (76, 82),
                 (90, 65), (93, 81), (76, 94), (61, 80)],
                closed: true
            )
            return Self(primary: body, details: keys, engraving: [], silhouettes: [bell])
        default:
            return nil
        }
    }
}
