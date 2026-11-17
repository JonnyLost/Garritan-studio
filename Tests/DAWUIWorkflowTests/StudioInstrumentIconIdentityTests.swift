import XCTest
@testable import DAWUI

/// Regression coverage for distinct physical instruments, independent of
/// Garritan bank/preset/keyswitch routing.
final class StudioInstrumentIconIdentityTests: XCTestCase {
    private func assertIcon(_ patch: String, _ expected: InstrumentIconIdentity,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            InstrumentIconIdentity.resolve(name: patch, path: "", category: ""),
            expected, "Incorrect instrument artwork for \(patch)",
            file: file, line: line
        )
    }

    func testClarinetVariants() {
        assertIcon("E-flat Clarinet Solo", .ebClarinet)
        assertIcon("Bb Clarinet Solo", .bbClarinet)
        assertIcon("B♭ Clarinet", .bbClarinet)
        assertIcon("Clarinet in A", .aClarinet)
        assertIcon("A Clarinet Solo", .aClarinet)
        assertIcon("Alto Clarinet", .altoClarinet)
        assertIcon("Bass Clarinet", .bassClarinet)
        assertIcon("Contrabass Clarinet", .contrabassClarinet)
        assertIcon("Clarinet Solo", .clarinet)
    }

    func testDistinctBrassShapesAndPriority() {
        assertIcon("Trumpet 1 Solo KS", .trumpet)
        assertIcon("Piccolo Trumpet KS", .piccoloTrumpet)
        assertIcon("C Trumpet", .cTrumpet)
        assertIcon("B-flat Trumpet", .bbTrumpet)
        assertIcon("Cornet Solo", .cornet)
        assertIcon("Flugelhorn Solo", .flugelhorn)
        assertIcon("Flügelhorn", .flugelhorn)
        assertIcon("Baritone Horn", .baritoneHorn)
        assertIcon("Euphonium", .euphonium)
        assertIcon("Bass Trombone", .bassTrombone)
        assertIcon("Contrabass Trombone", .contrabassTrombone)
    }

    func testMarchingAndDrumKitComponentsAreNotGenericDrums() {
        let expected: [(String, InstrumentIconIdentity)] = [
            ("Concert Snare", .snare),
            ("Marching Snare", .fieldSnare),
            ("Field Drum", .fieldSnare),
            ("Tenor Drums", .marchingTenors),
            ("Tenor Quads", .marchingTenors),
            ("Concert Bass Drum", .bassDrum),
            ("Kick Drum", .kickDrum),
            ("Rack Tom", .rackTom),
            ("Floor Tom", .floorTom),
            ("Drum Kit", .drumKit),
            ("Hi-Hat", .hiHat),
            ("Ride Cymbal", .rideCymbal),
            ("Crash Cymbals", .crashCymbals),
            ("Suspended Cymbal", .suspendedCymbal),
            ("Anvil", .anvil),
            ("Slapstick", .slapstick)
        ]
        for (patch, identity) in expected {
            assertIcon(patch, identity)
        }
    }

    func testInstrumentAndSectionRemainDistinct() {
        XCTAssertEqual(InstrumentIconIdentity.resolve(name: "Violins 1 KS", path: "", category: ""), .violin)
        XCTAssertEqual(StudioInstrumentGroupArtwork.resolve(name: "Violins 1 KS"), .violins)
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Violin 1 Solo KS"))
        XCTAssertEqual(StudioInstrumentGroupArtwork.resolve(name: "Marching Percussion"), .drumline)
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "Marching Snare Solo"))
        XCTAssertNil(StudioInstrumentGroupArtwork.resolve(name: "B-flat Clarinet Solo"))
    }

    func testNewIdentitiesHaveUsefulAccessibilityNames() {
        let identities: [InstrumentIconIdentity] = [
            .aClarinet, .bbClarinet, .cornet, .flugelhorn, .contrabassTrombone,
            .baritoneHorn, .fieldSnare, .marchingTenors, .kickDrum, .rackTom,
            .floorTom, .drumKit, .hiHat, .rideCymbal, .crashCymbals,
            .suspendedCymbal, .anvil, .slapstick
        ]
        XCTAssertEqual(identities.count, 18)
        for identity in identities {
            XCTAssertFalse(identity.accessibilityLabel.isEmpty)
        }
    }
}
