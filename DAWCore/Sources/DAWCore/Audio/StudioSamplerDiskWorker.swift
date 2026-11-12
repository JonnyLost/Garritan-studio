import Foundation
import StudioSamplerDSP

/// A single background decoder per streaming instrument, owning every
/// AVAudioFile reader on one serial DispatchQueue. This worker never runs
/// inside AVAudioSourceNode's real-time callback.
///
/// The C++ sampler owns fixed four-page buffers per voice; this class supplies
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
        // Lazy, bounded file handles: large libraries can contain hundreds
        // of sampled zones. Do not open every source recording at startup.
        // Readers stay confined to this one serial background queue.
        var readers: [Int: StudioSamplerDiskChunkReader] = [:]
        var recentlyUsed: [Int] = []
        let maxOpenReaders = 16

        while !stopped {
            var processed = 0
            while processed < 64 && !stopped {
                var request = SSStreamRequest()
                guard ss_stream_claim(sampler, &request) == 1 else { break }
                processed += 1

                let index = Int(request.zone_index)
                guard index >= 0, index < sourceURLs.count,
                      let url = sourceURLs[index] else {
                    ss_stream_abandon(sampler, &request)
                    continue
                }
                do {
                    let reader: StudioSamplerDiskChunkReader
                    if let existing = readers[index] {
                        reader = existing
                    } else {
                        reader = try StudioSamplerDiskChunkReader(url: url)
                        readers[index] = reader
                    }
                    recentlyUsed.removeAll(where: { $0 == index })
                    recentlyUsed.append(index)
                    if readers.count > maxOpenReaders {
                        let oldest = recentlyUsed.removeFirst()
                        readers.removeValue(forKey: oldest)
                    }

                    // Zero intermediate Swift Float arrays: the worker's
                    // reusable AVAudioPCMBuffer is copied directly into the
                    // fixed C++ buffer before the callback returns.
                    let supplied = try reader.withPage(
                        startFrame: Int64(request.start_frame),
                        requestedFrames: Int(request.frame_count)
                    ) { left, right, count in
                        ss_stream_supply(
                            sampler, &request, left, right, UInt32(count)
                        ) == 1
                    }
                    if !supplied { ss_stream_abandon(sampler, &request) }
                } catch {
                    // Errors affect this requested page, never the audio
                    // callback. The next prefetch can retry after an I/O
                    // failure; underrun fading handles the missing PCM.
                    ss_stream_abandon(sampler, &request)
                }
            }
            if processed == 0 {
                // The only sleep/polling is on this background worker.
                // 250 ms of preloaded attacks covers normal wake delays.
                Thread.sleep(forTimeInterval: 0.020)
            }
        }
    }
}
