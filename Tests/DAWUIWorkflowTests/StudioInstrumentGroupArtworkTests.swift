import XCTest
@testable import DAWUI

final class StudioInstrumentGroupArtworkTests: XCTestCase {
    private func assertGroup(_ patch: String, _ expected: StudioInstrumentGroupArtwork,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(StudioInstrumentGroupArtwork.resolve(name: patch), expected,
                       "Group artwork mismatch for \(patch)", file: file, line: line)
    }

    func testGPO5PatchNamesDistinguishSolosAndSections() {
        // Names appear in the repository's GPO5 manual-derived keyswitch catalog.
        assertGroup("Violins 1 KS", .violins)
        assertGroup("Violins 2 Short Bows KS", .violins)
        assertGroup("3 Violins Grp 1 KS", .violins)
        assertGroup("4 Violas KS", .violas)
        assertGroup("3 Cellos KS", .cellos)
        assertGroup("2 Basses KS", .basses)
        assertGroup("Full Strings Short Bows KS", .strings)
        assertGroup("SAM French Horn Section KS", .horns)
        assertGroup("Full Choir KS", .choir)
        assertGroup("Percussion Accessories KS", .percussion)
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Violin 1 Solo KS"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "French Horn 1 Plr1 KS"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "SAM Trumpet Solo KS"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Piccolo Solo KS"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Bass Clarinet Solo"))
    }

    func testSectionAndOrchestralCombinations() {
        let expected: [(String, StudioInstrumentGroupArtwork)] = [
            ("High Strings Ensemble", .highStrings),
            ("Low Strings", .lowStrings),
            ("String Orchestra", .strings),
            ("Clarinet Section", .clarinets),
            ("Saxophone Section", .saxophones),
            ("Woodwind Ensemble", .woodwinds),
            ("Trumpet Section", .trumpets),
            ("Trombone Section", .trombones),
            ("High Brass", .highBrass),
            ("Low Brass", .lowBrass),
            ("Brass Ensemble", .brass),
            ("Orchestra Tutti", .orchestra),
            ("Orchestral Combination", .mixedEnsemble),
            ("Percussion Section", .percussion),
            ("French Horn Section", .horns),
            ("Flute Section", .flutes),
            ("Viola Section", .violas),
            ("Cello Section", .cellos),
            ("Double Bass Section", .basses)
        ]
        for (patch, artwork) in expected {
            assertGroup(patch, artwork)
        }
    }

    func testAmbiguousInstrumentNamesDoNotInventSections() {
        for solo in [
            "Baritone Sax Solo", "Alto Flute Solo", "French Horn 1 Solo KS",
            "Trombone Plr1 KS", "High Strings Solo", "Bass Drum Solo",
            "Violin 1 KS", "SAM Trumpet Plr3 KS", "Mysterious Orchestra Pad",
            "Big and Bold", "Layers in Motion"
        ] {
            // A label that isn't explicitly identifiable as a group is
            // allowed to fall back rather than claiming a fictitious lineup.
            if solo == "High Strings Solo" { continue } // Explicit group label still wins.
            XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: solo),
                         "Unexpected section identification for \(solo)")
        }
        assertGroup("High Strings Solo", .highStrings)
    }

    func testAllGroupIdentitiesHaveAccessibleLabels() {
        XCTAssertEqual(StudioInstrumentGroupArtwork.allCases.count, 21)
        for group in StudioInstrumentGroupArtwork.allCases {
            XCTAssertFalse(group.accessibilityLabel.isEmpty)
        }
    }
}
