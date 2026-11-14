import XCTest
import AudioToolbox
@testable import DAWCore

/// No audio hardware is needed: topology snapshots are prepared on the
/// non-render control domain before the output callback is resumed.
final class StudioRenderGraphSnapshotTests: XCTestCase {
    func testEmptyGraphAndDeterministicMembership() {
        let graph = RenderGraph(sampleRate: 48_000, bufferSize: 512)
        XCTAssertTrue(graph.renderSnapshotTrackIDs.isEmpty)
        XCTAssertEqual(graph.renderSnapshotGeneration, 0)

        let first = TrackID()
        let second = TrackID()
        graph.createTrack(id: first)
        graph.createTrack(id: second)

        XCTAssertEqual(Set(graph.renderSnapshotTrackIDs), Set([first, second]))
        XCTAssertEqual(graph.renderSnapshotGeneration, 2)

        let before = graph.renderSnapshotGeneration
        graph.createTrack(id: first) // duplicate does not republish
        XCTAssertEqual(graph.renderSnapshotGeneration, before)
    }

    func testTopologyRemovalAndNonTopologyParameterChanges() {
        let graph = RenderGraph(sampleRate: 44_100, bufferSize: 256)
        let track = TrackID()
        graph.createTrack(id: track)
        let revision = graph.renderSnapshotGeneration

        graph.setTrackVolume(0.5, for: track)
        graph.setTrackPan(-0.25, for: track)
        graph.setTrackMute(true, for: track)
        XCTAssertEqual(graph.renderSnapshotGeneration, revision)
        XCTAssertEqual(graph.renderSnapshotTrackIDs, [track])

        graph.removeTrack(id: track)
        XCTAssertTrue(graph.renderSnapshotTrackIDs.isEmpty)
        XCTAssertEqual(graph.renderSnapshotGeneration, revision + 1)
        graph.removeTrack(id: track)
        XCTAssertEqual(graph.renderSnapshotGeneration, revision + 1)
    }

    func testMembershipRemainsStableAcrossBufferReallocation() {
        let graph = RenderGraph(sampleRate: 96_000, bufferSize: 128)
        let a = TrackID(), b = TrackID()
        graph.createTrack(id: a)
        graph.createTrack(id: b)
        let members = graph.renderSnapshotTrackIDs
        let revision = graph.renderSnapshotGeneration
        graph.setBufferSize(1024)
        XCTAssertEqual(graph.renderSnapshotTrackIDs, members)
        XCTAssertEqual(graph.renderSnapshotGeneration, revision)
    }

    func testFailedEffectPreparationDoesNotMutateActiveRouting() {
        let graph = RenderGraph(sampleRate: 48_000, bufferSize: 512)
        let track = TrackID()
        graph.createTrack(id: track)
        let revision = graph.renderSnapshotGeneration
        let members = graph.renderSnapshotTrackIDs

        // An invalid component must fail during preparation, before install.
        let invalid = AudioComponentDescription(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        XCTAssertThrowsError(try graph.prepareEffect(invalid))
        XCTAssertEqual(graph.renderSnapshotGeneration, revision)
        XCTAssertEqual(graph.renderSnapshotTrackIDs, members)
    }
}
