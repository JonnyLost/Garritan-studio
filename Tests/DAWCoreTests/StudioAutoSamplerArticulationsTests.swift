import XCTest
import AudioToolbox
@testable import DAWCore

final class StudioAutoSamplerArticulationsTests: XCTestCase {
    func testDefaultCapturePreservesOriginalSingleSound() {
        let plan = StudioAutoSamplerArticulations.Plan()
        XCTAssertTrue(plan.isValid(for: [48, 60], velocities: [64, 112],
                                      captureReleases: false))
        XCTAssertEqual(plan.effectiveEntries.count, 1)
        XCTAssertEqual(plan.effectiveEntries[0].name, "Sustain")
    }

    func testTwoKeyswitchesFitNativeZoneBudget() {
        let plan = StudioAutoSamplerArticulations.Plan(entries: [
            .init(name: "Sustain", sourceKeyswitch: 24),
            .init(name: "Staccato", sourceKeyswitch: 25)
        ], sourceChannel: 2)
        XCTAssertTrue(plan.isValid)
        XCTAssertTrue(plan.isValid(for: [48, 60, 72],
                                   velocities: [64, 112],
                                   captureReleases: false))
        XCTAssertFalse(plan.isValid(for: [48, 60, 72],
                                    velocities: [64, 112],
                                    captureReleases: true))
        XCTAssertFalse(plan.isValid(for: [24, 48],
                                    velocities: [64, 112],
                                    captureReleases: false))
        XCTAssertFalse(plan.isValid(for: Array(40...100).map(UInt8.init),
                                    velocities: [64, 112],
                                    captureReleases: false))
    }

    func testRejectsAmbiguousSourceSwitchesAndInvalidNames() {
        let sameSwitch = StudioAutoSamplerArticulations.Plan(entries: [
            .init(name: "Sustain", sourceKeyswitch: 24),
            .init(name: "Pizzicato", sourceKeyswitch: 24)
        ])
        XCTAssertFalse(sameSwitch.isValid)
        let missingDefault = StudioAutoSamplerArticulations.Plan(entries: [
            .init(name: "Legato", sourceKeyswitch: 24),
            .init(name: "Staccato", sourceKeyswitch: 25)
        ])
        XCTAssertFalse(missingDefault.isValid)
        let duplicateNames = StudioAutoSamplerArticulations.Plan(entries: [
            .init(name: "Sustain", sourceKeyswitch: 24),
            .init(name: "sustain", sourceKeyswitch: 25)
        ])
        XCTAssertFalse(duplicateNames.isValid)
    }

    func testFifteenArticulationsAreSupportedWithinZoneBudget() {
        let names = ["Sustain", "Legato", "Staccato", "Pizzicato",
                     "Tremolo", "Trill", "Marcato", "Spiccato",
                     "Sforzando", "Flutter", "Harmonics", "Sul Pont",
                     "Sul Tasto", "Muted", "Col Legno"]
        let entries = names.enumerated().map { index, name in
            StudioAutoSamplerArticulations.Entry(
                name: name, sourceKeyswitch: UInt8(index + 20))
        }
        let plan = StudioAutoSamplerArticulations.Plan(entries: entries)
        XCTAssertTrue(plan.isValid)
        XCTAssertTrue(plan.isValid(for: [48, 60, 72, 84],
                                   velocities: [64, 112],
                                   captureReleases: false))
        XCTAssertFalse(plan.isValid(for: [48, 60, 72, 84, 96],
                                    velocities: [32, 64, 96, 120],
                                    captureReleases: false))
        let overflow = StudioAutoSamplerArticulations.Plan(
            entries: entries + [.init(name: "Sixteenth", sourceKeyswitch: 40)])
        XCTAssertFalse(overflow.isValid)
    }

    func testFactoryBuildsDistinctNativeArticulationAssignments() throws {
        let directory = FileManager.default.temporaryDirectory
        let entries = ["Sustain", "Staccato", "Pizzicato"]
        let takes = entries.enumerated().map { index, name in
            StudioSamplerFactoryTake(
                source: directory.appendingPathComponent("art-\\(index).wav"),
                rootNote: 60, velocity: 100, articulation: name)
        }
        let patch = try StudioSamplerInstrumentFactory.assemble(takes)
        XCTAssertTrue(patch.isValid)
        XCTAssertEqual(patch.zones.count, 3)
        XCTAssertEqual(patch.zones.filter { $0.articulationID == nil }.count, 1)
        XCTAssertEqual(patch.articulations?.count, 2)
        XCTAssertEqual(Set(patch.articulations?.map(\\.keyswitchNote) ?? []).count, 2)
    }

    func testCapturePreflightRejectsArticulationBudgetBeforeLoadingAU() async {
        let fake = StudioAutoSamplerCapture.Source(
            type: kAudioUnitType_MusicDevice, subtype: 0, manufacturer: 0,
            name: "No AU", vendor: "Test")
        let plan = StudioAutoSamplerArticulations.Plan(entries: [
            .init(name: "Sustain", sourceKeyswitch: 24),
            .init(name: "Staccato", sourceKeyswitch: 25)
        ])
        do {
            _ = try await StudioAutoSamplerCapture.capture(
                source: fake, name: "Reject oversized multisound",
                options: .init(rootNotes: Array(40...100).map(UInt8.init),
                               velocities: [64, 112]),
                articulations: plan)
            XCTFail("Must reject before instantiating an AU")
        } catch StudioAutoSamplerCapture.CaptureError.invalidConfiguration {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
