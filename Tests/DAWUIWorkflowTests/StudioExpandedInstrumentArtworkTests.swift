import XCTest
@testable import DAWUI

/// Name-based identity checks for the additional catalog families. The
/// installed Garritan bank XML remains the source of truth for future full
/// library-by-library coverage audits.
final class StudioExpandedInstrumentArtworkTests: XCTestCase {
    private func assertIcon(_ patch: String, _ expected: InstrumentIconIdentity,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            InstrumentIconIdentity.resolve(name: patch, path: "", category: ""),
            expected, "Artwork mismatch for \(patch)", file: file, line: line
        )
    }

    func testOrchestralMarchingAndWorldPercussion() {
        let cases: [(String, InstrumentIconIdentity)] = [
            ("Marching Bass Drum", .marchingBassDrum),
            ("Splash Cymbal", .splashCymbal),
            ("China Cymbal", .chinaCymbal),
            ("Thunder Sheet", .thunderSheet),
            ("Rain Stick", .rainstick),
            ("Bongos", .bongos),
            ("Congas", .congas),
            ("Djembe", .djembe),
            ("Tabla", .tabla),
            ("Taiko Drum", .taiko)
        ]
        for (name, expected) in cases {
            assertIcon(name, expected)
        }
        assertIcon("Concert Bass Drum", .bassDrum)
        assertIcon("Crash Cymbals", .crashCymbals)
        assertIcon("Ride Cymbal", .rideCymbal)
        assertIcon("Marching Snare Solo", .fieldSnare)
    }

    func testDistinctGuitarAndBassInstruments() {
        let cases: [(String, InstrumentIconIdentity)] = [
            ("Guitar", .guitar),
            ("Acoustic Guitar", .acousticGuitar),
            ("Classical Guitar", .classicalGuitar),
            ("Electric Guitar", .electricGuitar),
            ("Electric Bass", .electricBass),
            ("Upright Bass", .uprightBass),
            ("Banjo", .banjo),
            ("Mandolin", .mandolin),
            ("Ukulele", .ukulele)
        ]
        for (name, expected) in cases {
            assertIcon(name, expected)
        }
        assertIcon("Double Bass 1 Solo KS", .doubleBass)
        assertIcon("Bass Guitar", .electricBass)
        assertIcon("Fretless Bass Guitar", .electricBass)
    }

    func testKeyboardsAndOtherWorldInstruments() {
        let cases: [(String, InstrumentIconIdentity)] = [
            ("Upright Piano", .uprightPiano),
            ("Electric Piano", .electricPiano),
            ("Clavinet", .clavinet),
            ("Accordion", .accordion),
            ("Sitar", .sitar),
            ("Oud", .oud),
            ("Erhu", .erhu),
            ("Koto", .koto),
            ("Shakuhachi", .shakuhachi),
            ("Pan Flute", .panFlute)
        ]
        for (name, expected) in cases {
            assertIcon(name, expected)
        }
        assertIcon("Concert Grand Piano", .piano)
        assertIcon("Piccolo Solo KS", .piccolo)
        assertIcon("Bass Flute", .bassFlute)
    }

    func testExpandedSectionIdentities() {
        let cases: [(String, StudioInstrumentGroupArtwork)] = [
            ("Guitar Ensemble", .guitarSection),
            ("Rhythm Section", .rhythmSection),
            ("World Percussion Ensemble", .worldPercussion),
            ("Concert Band", .concertBand),
            ("Marching Band", .marchingBand)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(StudioInstrumentGroupArtwork.resolve(name: name), expected)
        }
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Electric Guitar Solo"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Marching Bass Drum"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Tabla Solo"))
        XCTAssertEqual(StudioInstrumentGroupArtwork.allCases.count, 34)
    }

    func testExpandedIdentitiesHaveAccessibleLabelsAndDrawings() {
        let identities: [InstrumentIconIdentity] = [
            .marchingBassDrum, .splashCymbal, .chinaCymbal, .thunderSheet, .rainstick,
            .bongos, .congas, .djembe, .tabla, .taiko,
            .guitar, .acousticGuitar, .classicalGuitar, .electricGuitar, .electricBass,
            .uprightBass, .banjo, .mandolin, .ukulele,
            .uprightPiano, .electricPiano, .clavinet, .accordion,
            .sitar, .oud, .erhu, .koto, .shakuhachi, .panFlute
        ]
        XCTAssertEqual(identities.count, 29)
        for identity in identities {
            XCTAssertFalse(identity.accessibilityLabel.isEmpty)
            let art = InstrumentIconDrawing.make(identity)
            XCTAssertFalse(art.primary.isEmpty,
                           "Missing native icon geometry for \(identity)")
        }
    }
}
