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

    func testNewEmptyTracksCanPublishWhileRenderReadsAnOlderSnapshot() {
        struct StereoList {
            var mNumberBuffers: UInt32 = 2
            var left = AudioBuffer()
            var right = AudioBuffer()
        }
        let graph = RenderGraph(sampleRate: 48_000, bufferSize: 128)
        let queue = DispatchQueue(label: "studio.route.snapshot.render", qos: .userInitiated)
        let finished = expectation(description: "render reader finished")
        queue.async {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            defer { left.deallocate(); right.deallocate() }
            left.initialize(repeating: 0, count: 128)
            right.initialize(repeating: 0, count: 128)
            var stereo = StereoList()
            stereo.left = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: left)
            stereo.right = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: right)
            for tick in 0..<400 {
                withUnsafeMutablePointer(to: &stereo) { ptr in
                    ptr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { buffers in
                        graph.render(
                            frameCount: 128,
                            currentSample: Int64(tick * 128),
                            outputBuffer: buffers
                        )
                    }
                }
            }
            finished.fulfill()
        }
        for _ in 0..<64 { graph.createTrack(id: TrackID()) }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(graph.renderSnapshotTrackIDs.count, 64)
        XCTAssertEqual(graph.renderSnapshotGeneration, 64)
    }
}
