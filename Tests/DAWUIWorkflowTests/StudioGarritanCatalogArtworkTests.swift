import XCTest
@testable import DAWUI

/// The following sample names come from Garritan's published product lists
/// (not from an exhaustive inspection of the user's installed bank XML).
final class StudioGarritanCatalogArtworkTests: XCTestCase {
    private func icon(_ patch: String) -> InstrumentIconIdentity {
        InstrumentIconIdentity.resolve(name: patch, path: "", category: "")
    }

    func testPublishedJazzSaxophoneVariants() {
        let examples: [(String, InstrumentIconIdentity)] = [
            ("Sopranino Sax", .sopraninoSaxophone),
            ("Mezzo Soprano Sax", .mezzoSopranoSaxophone),
            ("Curved Soprano Sax", .curvedSopranoSaxophone),
            ("C Melody Sax", .cMelodySaxophone),
            ("Contrabass Sax", .contrabassSaxophone),
            ("Sub-Contrabass Sax", .subcontrabassSaxophone)
        ]
        for (name, expected) in examples {
            XCTAssertEqual(icon(name), expected, name)
        }
        XCTAssertEqual(icon("Bass Sax"), .bassSaxophone)
        XCTAssertEqual(icon("Baritone Sax"), .baritoneSaxophone)
        XCTAssertEqual(icon("Straight Soprano Sax"), .sopranoSaxophone)
    }

    func testConcertAndMarchingBandVariants() {
        let examples: [(String, InstrumentIconIdentity)] = [
            ("Mellophone Solo", .mellophone),
            ("Tenor Horn Solo", .tenorHorn),
            ("Sousaphone Solo", .sousaphone),
            ("Helicon Solo", .helicon),
            ("Roto Toms", .rotoToms),
            ("Flexitone", .flexatone),
            ("Sarrusophone Solo", .sarrusophone)
        ]
        for (name, expected) in examples {
            XCTAssertEqual(icon(name), expected, name)
        }
        XCTAssertEqual(icon("French Horn Solo"), .horn)
        XCTAssertEqual(icon("Baritone Horn Solo"), .baritoneHorn)
    }

    func testPublishedWorldAndJazzWindsPercussion() {
        let examples: [(String, InstrumentIconIdentity)] = [
            ("Bansuri 1", .bansuri),
            ("Duduk", .duduk),
            ("Didgeridoo", .didgeridoo),
            ("Highland Bagpipes", .bagpipes),
            ("Mbira", .mbira),
            ("Harmonica", .harmonica),
            ("Timbales", .timbales),
            ("Alto Recorder", .recorder)
        ]
        for (name, expected) in examples {
            XCTAssertEqual(icon(name), expected, name)
        }
    }

    func testAdditionalSectionAndNamedEnsembleArtwork() {
        let examples: [(String, StudioInstrumentGroupArtwork)] = [
            ("Piccolo Group 1", .piccolos),
            ("Cornet Group 2", .cornets),
            ("Flugelhorn Group 1", .flugelhorns),
            ("Mellophone Group 3", .mellophones),
            ("Tenor Horn Group 1", .tenorHorns),
            ("Euphonium Group 4", .euphoniums),
            ("Baritone Group 2", .baritoneHorns),
            ("Tuba Group 1", .tubas),
            ("Sousaphone Group 1", .sousaphones),
            ("Helicon Group 2", .helicons),
            ("Big Band #1", .jazzBigBand),
            ("African Orchestra", .worldEnsemble),
            ("Strings and Winds Sustains", .stringsAndWinds),
            ("Strings and Brass", .stringsAndBrass),
            ("Soft Winds and Brass", .windsAndBrass),
            ("Lush Orchestra Octaves and Choir", .orchestraAndChoir),
            ("Full Orchestra Portato", .orchestra),
            ("Japanese Taiko Ensemble", .worldPercussion)
        ]
        for (name, expected) in examples {
            XCTAssertEqual(StudioInstrumentGroupArtwork.resolve(name: name),
                           expected, name)
        }
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Sopranino Sax Solo"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Cornet Solo"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Mellophone Solo"))
        XCTAssertEqual(StudioInstrumentGroupArtwork.allCases.count, 50)
    }

    func testAllNewDrawingsExistAndHaveAccessibleNames() {
        let identities: [InstrumentIconIdentity] = [
            .sopraninoSaxophone, .mezzoSopranoSaxophone, .curvedSopranoSaxophone,
            .cMelodySaxophone, .contrabassSaxophone, .subcontrabassSaxophone,
            .mellophone, .tenorHorn, .sousaphone, .helicon,
            .bansuri, .duduk, .didgeridoo, .bagpipes, .mbira,
            .harmonica, .timbales, .rotoToms, .flexatone,
            .recorder, .sarrusophone
        ]
        XCTAssertEqual(identities.count, 21)
        for identity in identities {
            XCTAssertFalse(identity.accessibilityLabel.isEmpty)
            XCTAssertFalse(InstrumentIconDrawing.make(identity).primary.isEmpty,
                           "Missing drawing: \(identity)")
        }
    }

    func testStableAssetKeyAndSoloSectionDistinction() {
        XCTAssertEqual(
            StudioInstrumentArtworkAssets.key(name: "Mellophone Solo"),
            "instrument_mellophone"
        )
        XCTAssertEqual(
            StudioInstrumentArtworkAssets.key(name: "Mellophone Group 1"),
            "ensemble_mellophones"
        )
        XCTAssertEqual(
            StudioInstrumentArtworkAssets.key(name: "Sub-Contrabass Sax"),
            "instrument_subcontrabassSaxophone"
        )
        XCTAssertEqual(
            StudioInstrumentArtworkAssets.key(name: "Full Orchestra Portato"),
            "ensemble_orchestra"
        )
        XCTAssertEqual(
            StudioInstrumentArtworkAssets.key(name: "Bansuri 1"),
            "instrument_bansuri"
        )
    }
}
