import Foundation
import AudioToolbox
import AVFoundation
import DAWRealtime

// MARK: - Studio's native experimental audio clip disk streamer

/// Four fixed C11-atomic stereo pages per clip. One dedicated serial worker
/// owns every ExtAudioFile decoder. The Core Audio callback NEVER reads files,
/// waits for I/O, changes graph ownership, resizes PCM storage, or logs.
///
/// This is still experimental: file/graph mutation requires stopped playback.
/// Cached page misses produce bounded silence and count underrun frames.
public final class AudioClipRenderer {
    static let pageFrames = 4096
    static let pageCount = 4

    private final class ScheduledClip {
        let trackID: TrackID
        let file: ExtAudioFileRef
        let cache: OpaquePointer
        let startSample: Int64
        let offsetSample: Int64
        let endSample: Int64
        let volume: Float

        init(trackID: TrackID, file: ExtAudioFileRef, cache: OpaquePointer,
             startSample: Int64, offsetSample: Int64,
             endSample: Int64, volume: Float) {
            self.trackID = trackID
            self.file = file
            self.cache = cache
            self.startSample = startSample
            self.offsetSample = offsetSample
            self.endSample = endSample
            self.volume = volume
        }

        func dispose() {
            ExtAudioFileDispose(file)
            daw_pcm_page_cache_destroy(cache)
        }
    }

    private let sampleRate: Double
    private let workerQueue = DispatchQueue(
        label: "studio.coreaudio.clip-disk", qos: .userInitiated
    )
    // The disk worker is the sole writer of scheduledClips; the render
    // callback reads it only during playback, when graph edits are forbidden.
    private var scheduledClips: [ScheduledClip] = []
    private var timer: DispatchSourceTimer?
    // Worker-only, bounded reusable stereo interleaved scratch.
    private let scratch: UnsafeMutablePointer<Float>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        scratch = .allocate(capacity: Self.pageFrames * 2)
        scratch.initialize(repeating: 0, count: Self.pageFrames * 2)
    }

    deinit {
        // Callers must stop the output unit before retiring the backend.
        workerQueue.sync {
            timer?.cancel()
            timer = nil
            for clip in scheduledClips { clip.dispose() }
            scheduledClips.removeAll()
        }
        scratch.deinitialize(count: Self.pageFrames * 2)
        scratch.deallocate()
    }

    /// Configure the decoder on a non-render thread before starting audio.
    func scheduleClip(
        url: URL,
        trackID: TrackID,
        startSample: Int64,
        offsetSample: Int64,
        endSample: Int64,
        volume: Float
    ) throws {
        guard startSample >= 0, offsetSample >= 0, endSample > startSample,
              volume.isFinite, sampleRate.isFinite, sampleRate > 0 else {
            throw AudioBackendError.configurationError(
                "Invalid audio clip timeline, offset, volume or sample rate"
            )
        }

        var reference: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &reference)
        guard openStatus == noErr, let file = reference else {
            throw AudioBackendError.audioFileLoadFailed(
                url, "ExtAudioFileOpenURL failed: \(openStatus)"
            )
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format
        )
        guard formatStatus == noErr else {
            ExtAudioFileDispose(file)
            throw AudioBackendError.audioFileLoadFailed(
                url, "Stereo decoder configuration failed: \(formatStatus)"
            )
        }
        guard let cache = daw_pcm_page_cache_create(
            UInt32(Self.pageFrames), UInt32(Self.pageCount)
        ) else {
            ExtAudioFileDispose(file)
            throw AudioBackendError.configurationError(
                "Cannot allocate bounded audio streaming pages"
            )
        }

        let clip = ScheduledClip(
            trackID: trackID, file: file, cache: cache,
            startSample: startSample, offsetSample: offsetSample,
            endSample: endSample, volume: volume
        )
        workerQueue.sync {
            scheduledClips.append(clip)
        }
    }

    /// Called only when hardware playback is stopped/inactive.
    /// Decode the first requested page for every clip before the first
    /// callback, then stream additional pages on the background worker.
    func preparePlayback(at playheadSample: Int64) {
        workerQueue.sync {
            stopTimer()
            for clip in scheduledClips {
                let clipFrame = playheadSample <= clip.startSample
                    ? Int64(0) : playheadSample - clip.startSample
                daw_pcm_page_cache_request(clip.cache, UInt64(clipFrame))
                let firstPage = UInt64(clipFrame) / UInt64(Self.pageFrames)
                fillPage(clip, page: firstPage)
            }
            let source = DispatchSource.makeTimerSource(queue: workerQueue)
            source.schedule(
                deadline: .now() + .milliseconds(5),
                repeating: .milliseconds(10)
            )
            source.setEventHandler { [weak self] in
                self?.fillRequestedPages()
            }
            timer = source
            source.resume()
        }
    }

    func pauseStreaming() {
        workerQueue.sync { stopTimer() }
    }

    func clearClips() {
        workerQueue.sync {
            stopTimer()
            for clip in scheduledClips { clip.dispose() }
            scheduledClips.removeAll(keepingCapacity: true)
        }
    }

    /// Called exclusively from the serial disk worker.
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func fillRequestedPages() {
        for clip in scheduledClips {
            var firstPage: UInt64 = 0
            guard daw_pcm_page_cache_requested_page(clip.cache, &firstPage) else {
                continue
            }
            for delta in 0..<Self.pageCount {
                let (page, overflow) = firstPage.addingReportingOverflow(UInt64(delta))
                guard !overflow else { break }
                fillPage(clip, page: page)
            }
        }
    }

    /// All seek/format conversion/disk reading happens on workerQueue.
    private func fillPage(_ clip: ScheduledClip, page: UInt64) {
        if daw_pcm_page_cache_contains(clip.cache, page) { return }
        guard page <= UInt64(Int64.max / Int64(Self.pageFrames)) else { return }
        let pageFrame = Int64(page) * Int64(Self.pageFrames)
        let duration = clip.endSample - clip.startSample
        guard pageFrame < duration else { return }
        let (fileFrame, overflow) = clip.offsetSample.addingReportingOverflow(pageFrame)
        guard !overflow else { return }

        // Clear the worker's shared scratch for short reads / end-of-file.
        memset(scratch, 0, Self.pageFrames * 2 * MemoryLayout<Float>.size)
        let seekStatus = ExtAudioFileSeek(clip.file, fileFrame)
        guard seekStatus == noErr else { return }

        let framesToRead = UInt32(min(Int64(Self.pageFrames), duration - pageFrame))
        var buffer = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: framesToRead * 8,
                mData: scratch
            )
        )
        var actualFrames = framesToRead
        let status = ExtAudioFileRead(clip.file, &actualFrames, &buffer)
        guard status == noErr else { return }
        // Even if the file ends early, the page is padded with silence by
        // the C cache. Never retry end-of-file inside the callback.
        _ = daw_pcm_page_cache_supply(clip.cache, page, scratch, actualFrames)
    }

    /// Audio render callback. Only C11-atomic page reads and floating-point
    /// mixing; no file reading, memory allocations, locks or console output.
    func render(
        into bufferList: UnsafeMutablePointer<AudioBufferList>,
        currentSample: Int64,
        frameCount: UInt32
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            return
        }
        let end = StudioMIDIClockMath.bufferEnd(
            startSample: currentSample, frameCount: frameCount
        )
        for clip in scheduledClips {
            let first = max(currentSample, clip.startSample)
            let last = min(end, clip.endSample)
            guard last > first else { continue }
            let offset = Int(first - currentSample)
            _ = daw_pcm_page_cache_mix(
                clip.cache, UInt64(first - clip.startSample),
                UInt32(last - first),
                left.advanced(by: offset), right.advanced(by: offset),
                clip.volume
            )
        }
    }

    /// Offline bounce is intentionally different from a real-time callback:
    /// seeking and reading the same decoder is permitted here. The serial
    /// worker owns the file, so disk I/O cannot race its page prefetching.
    func renderOffline(
        into bufferList: UnsafeMutablePointer<AudioBufferList>,
        currentSample: Int64,
        frameCount: UInt32
    ) {
        workerQueue.sync {
            let outputs = UnsafeMutableAudioBufferListPointer(bufferList)
            guard outputs.count >= 2,
                  let left = outputs[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = outputs[1].mData?.assumingMemoryBound(to: Float.self),
                  frameCount <= UInt32(Self.pageFrames) else { return }

            let end = StudioMIDIClockMath.bufferEnd(
                startSample: currentSample, frameCount: frameCount
            )
            for clip in scheduledClips {
                let first = max(currentSample, clip.startSample)
                let last = min(end, clip.endSample)
                guard last > first else { continue }
                let clipFrame = first - clip.startSample
                let (fileOffset, overflow) = clip.offsetSample.addingReportingOverflow(clipFrame)
                guard !overflow, ExtAudioFileSeek(clip.file, fileOffset) == noErr else {
                    continue
                }
                let count = UInt32(last - first)
                var buffer = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: count * 8,
                        mData: scratch
                    )
                )
                var actual = count
                guard ExtAudioFileRead(clip.file, &actual, &buffer) == noErr else {
                    continue
                }
                let dest = Int(first - currentSample)
                for index in 0..<Int(actual) {
                    left[dest + index] += scratch[index * 2] * clip.volume
                    right[dest + index] += scratch[index * 2 + 1] * clip.volume
                }
            }
        }
    }

    /// Query only on a non-real-time control thread while stopped.
    var totalUnderrunFrames: UInt64 {
        workerQueue.sync {
            scheduledClips.reduce(UInt64(0)) {
                $0 &+ daw_pcm_page_cache_underrun_frames($1.cache)
            }
        }
    }
}
