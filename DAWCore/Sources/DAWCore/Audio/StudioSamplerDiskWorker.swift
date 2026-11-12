import Foundation
import StudioSamplerDSP

/// A single background decoder per streaming instrument, owning every
/// AVAudioFile reader on one serial DispatchQueue. This worker never runs
/// inside AVAudioSourceNode's real-time callback.
///
/// The C++ sampler owns fixed two-page buffers per voice; this class supplies
/// those pages through a release/acquire handoff. There are no asynchronous
/// writes into buffers that the renderer is currently reading.
final class StudioSamplerDiskWorker: @unchecked Sendable {
    private let sampler: OpaquePointer
    private let sourceURLs: [URL?]
    private let queue = DispatchQueue(label: "com.garritan.studio.sampler.disk",
                                      qos: .userInitiated)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var shouldStop = false

    init(sampler: OpaquePointer, sourceURLs: [URL?]) {
        self.sampler = sampler
        self.sourceURLs = sourceURLs
        queue.async { [self] in
            run()
            finished.signal()
        }
    }

    /// Only call after detaching audio callbacks or when the sampler is
    /// otherwise no longer renderable. Must complete BEFORE ss_destroy().
    func shutdown() {
        stateLock.lock()
        shouldStop = true
        stateLock.unlock()
        finished.wait()
    }

    private var stopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    private func run() {
        // Open AVAudioFile and preserve its thread confinement. No reader is
        // created on the audio thread. Nil means a resident RAM-backed zone.
        let readers: [StudioSamplerDiskChunkReader?] = sourceURLs.map { url in
            guard let url else { return nil }
            return try? StudioSamplerDiskChunkReader(url: url)
        }
        while !stopped {
            var processed = 0
            // Limit the work per iteration to prevent a single instrument
            // from monopolizing an I/O worker at high polyphony.
            while processed < 64 && !stopped {
                var request = SSStreamRequest()
                guard ss_stream_claim(sampler, &request) == 1 else { break }
                processed += 1

                guard request.zone_index >= 0,
                      Int(request.zone_index) < readers.count,
                      let reader = readers[Int(request.zone_index)] else {
                    ss_stream_abandon(sampler, &request)
                    continue
                }
                do {
                    let page = try reader.readPage(
                        startFrame: Int64(request.start_frame),
                        requestedFrames: Int(request.frame_count)
                    )
                    let supplied = page.left.withUnsafeBufferPointer { left in
                        page.right.withUnsafeBufferPointer { right in
                            ss_stream_supply(
                                sampler, &request, left.baseAddress,
                                right.baseAddress, UInt32(page.frameCount)
                            ) == 1
                        }
                    }
                    if !supplied { ss_stream_abandon(sampler, &request) }
                } catch {
                    // I/O and decoding failures never block audio rendering.
                    // Another prefetch request can retry on a subsequent pass.
                    ss_stream_abandon(sampler, &request)
                }
            }
            if processed == 0 {
                // Idle sleep occurs only in the background worker. With
                // >250 ms of attack preload there is ample prefetch time.
                Thread.sleep(forTimeInterval: 0.012)
            }
        }
    }
}
