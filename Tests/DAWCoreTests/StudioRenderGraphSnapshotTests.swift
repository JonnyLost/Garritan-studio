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
        XCTAssertEqual(graph.renderSnapshotGeneration, revision + 1)
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

    func testPerTrackResourcesRemainOwnedUntilRouteRetires() {
        let graph = RenderGraph(sampleRate: 48_000, bufferSize: 256)
        let track = TrackID()
        graph.createTrack(id: track)
        XCTAssertTrue(graph.canRemoveEmptyTrackLive(id: track))
        XCTAssertEqual(graph.renderSnapshotTrackIDs, [track])

        graph.removeTrack(id: track)
        XCTAssertTrue(graph.renderSnapshotTrackIDs.isEmpty)
        XCTAssertEqual(graph.renderSnapshotGeneration, 2)
        XCTAssertFalse(graph.canRemoveEmptyTrackLive(id: track))

        // A new track with the same identity obtains a new scratch owner;
        // old snapshot resources are not reused by the new generation.
        graph.createTrack(id: track)
        XCTAssertEqual(graph.renderSnapshotTrackIDs, [track])
        XCTAssertEqual(graph.renderSnapshotGeneration, 3)
        graph.setBufferSize(1024)
        XCTAssertEqual(graph.renderSnapshotTrackIDs, [track])
        XCTAssertEqual(graph.renderSnapshotGeneration, 4)
    }

    func testLiveEmptyTrackRemovalAndAdditionDuringRender() {
        struct StereoList {
            var mNumberBuffers: UInt32 = 2
            var left = AudioBuffer()
            var right = AudioBuffer()
        }
        let graph = RenderGraph(sampleRate: 44_100, bufferSize: 128)
        let initial = TrackID()
        graph.createTrack(id: initial)
        let complete = expectation(description: "reader completed")
        DispatchQueue.global(qos: .userInitiated).async {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            defer { left.deallocate(); right.deallocate() }
            left.initialize(repeating: 0, count: 128)
            right.initialize(repeating: 0, count: 128)
            var list = StereoList()
            list.left = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: left)
            list.right = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: right)
            for index in 0..<300 {
                withUnsafeMutablePointer(to: &list) { pointer in
                    pointer.withMemoryRebound(to: AudioBufferList.self, capacity: 1) {
                        graph.render(frameCount: 128,
                                     currentSample: Int64(index * 128),
                                     outputBuffer: $0)
                    }
                }
            }
            complete.fulfill()
        }
        for _ in 0..<64 {
            let id = TrackID()
            graph.createTrack(id: id)
            XCTAssertTrue(graph.canRemoveEmptyTrackLive(id: id))
            graph.removeTrack(id: id)
        }
        wait(for: [complete], timeout: 10)
        XCTAssertEqual(graph.renderSnapshotTrackIDs, [initial])
    }
    func testProcessingResourcesAreVersionedIndependentlyOfMixerControls() {
        let graph = RenderGraph(sampleRate: 48_000, bufferSize: 128)
        let id = TrackID()
        graph.createTrack(id: id)

        let initialGeneration = graph.renderSnapshotGeneration
        let initialResource = try? XCTUnwrap(graph.publishedProcessingIdentity(for: id))
        XCTAssertEqual(graph.publishedScratchCapacity(for: id), 128)

        graph.setTrackVolume(0.25, for: id)
        graph.setTrackPan(-0.5, for: id)
        graph.setTrackMute(true, for: id)
        XCTAssertEqual(graph.renderSnapshotGeneration, initialGeneration)
        XCTAssertEqual(graph.publishedProcessingIdentity(for: id), initialResource)

        graph.setBufferSize(1024)
        XCTAssertEqual(graph.publishedScratchCapacity(for: id), 1024)
        XCTAssertNotEqual(graph.publishedProcessingIdentity(for: id), initialResource)
        XCTAssertEqual(graph.renderSnapshotGeneration, initialGeneration + 1)

        graph.removeTrack(id: id)
        XCTAssertNil(graph.publishedProcessingIdentity(for: id))
    }

    func testSeparateTracksOwnDistinctProcessingBundles() {
        let graph = RenderGraph(sampleRate: 44_100, bufferSize: 256)
        let a = TrackID(), b = TrackID()
        graph.createTrack(id: a)
        graph.createTrack(id: b)
        XCTAssertNotEqual(graph.publishedProcessingIdentity(for: a),
                          graph.publishedProcessingIdentity(for: b))
        XCTAssertTrue(graph.canRemoveEmptyTrackLive(id: a))
        XCTAssertTrue(graph.canRemoveEmptyTrackLive(id: b))
    }

}
