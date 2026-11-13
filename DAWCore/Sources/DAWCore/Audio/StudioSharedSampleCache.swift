import Foundation
import AVFoundation
import StudioSharedPCM

/// An immutable native PCM allocation. Its C++ reference count keeps memory
/// alive independently of cache eviction and even after this Swift object
/// deinitializes. Never retain/release this wrapper in an audio callback.
public final class StudioSharedPCMAsset: @unchecked Sendable {
    public let handle: OpaquePointer
    public let frames: Int
    public let sampleRate: Double
    public let residentBytes: Int

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
        frames = Int(sspcm_frames(handle))
        sampleRate = sspcm_sample_rate(handle)
        residentBytes = Int(sspcm_resident_bytes(handle))
    }

    deinit { sspcm_release(handle) }
}

/// Control-thread-only, bounded LRU for app-owned or imported recordings.
///
/// Identical file revisions and decoded frame windows return the same native
/// SSSharedPCM handle. Resident Sampler zones and Granular engines each retain
/// that handle for their entire playback lifetime; eviction only releases the
/// cache's reference and NEVER invalidates a live audio callback.
///
/// Long streamed Sampler recordings retain the existing streaming workflow.
/// This cache covers RAM-resident Sampler recordings and Granular's bounded
/// source window; it never calls AVAudioFile from the audio rendering thread.
public final class StudioSharedSampleCache: @unchecked Sendable {
    public static let shared = StudioSharedSampleCache()

    public struct Statistics: Sendable {
        public let hits: UInt64
        public let misses: UInt64
        public let entries: Int
        public let residentBytes: Int
        public let capacityBytes: Int
    }

    private struct Key: Hashable {
        let path: String
        let bytes: UInt64
        let modified: Date
        let fileID: UInt64
        let frames: Int
    }

    private struct Entry {
        var asset: StudioSharedPCMAsset
        var tick: UInt64
    }

    private let lock = NSLock()
    private let capacityBytes: Int
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0

    public init(maxBytes: Int = 64 * 1024 * 1024) {
        capacityBytes = max(0, maxBytes)
    }

    public func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(hits: hits, misses: misses,
                          entries: entries.count, residentBytes: bytes,
                          capacityBytes: capacityBytes)
    }

    /// Decode off the render thread. Returns nil if the source is outside the
    /// cache's two-million-frame limit (callers may use legacy copy/streaming).
    ///
    /// Cache keys include the canonical filename, file identity, modification
    /// timestamp, size and number of decoded frames. Editing a recording
    /// produces a different asset without disturbing already-playing notes.
    public func acquire(url: URL, maxFrames: Int) throws -> StudioSharedPCMAsset? {
        guard maxFrames >= 2 else { return nil }
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: normalized.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { return nil }

        // Acquire the AVAudioFile metadata off the render callback. An open
        // here is intentional: the hash key is the actual decoded frame span,
        // so full resident samples share with Granular's matching prefix.
        let file = try AVAudioFile(forReading: normalized,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else { return nil }
        let frames = Int(min(file.length, Int64(min(maxFrames, 2_000_000))))
        guard frames >= 2 else { return nil }
        let key = Key(path: normalized.path, bytes: size, modified: modified,
                      fileID: fileID, frames: frames)

        lock.lock()
        defer { lock.unlock() }
        clock &+= 1
        if var hit = entries[key] {
            hits &+= 1
            hit.tick = clock
            entries[key] = hit
            return hit.asset
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        guard buffer.frameLength == AVAudioFrameCount(frames),
              let channels = buffer.floatChannelData else { return nil }

        guard let handle = sspcm_create_copy(
            channels[0],
            format.channelCount == 2 ? channels[1] : nil,
            UInt32(frames), format.sampleRate)
        else { return nil }
        let asset = StudioSharedPCMAsset(handle: handle)
        misses &+= 1
        // A large source can still be used by the caller, but does not
        // displace the entire cache. Native engines retain it independently.
        guard asset.residentBytes <= capacityBytes else { return asset }
        while bytes + asset.residentBytes > capacityBytes,
              let oldest = entries.min(by: { $0.value.tick < $1.value.tick }) {
            bytes -= oldest.value.asset.residentBytes
            entries.removeValue(forKey: oldest.key)
        }
        entries[key] = Entry(asset: asset, tick: clock)
        bytes += asset.residentBytes
        return asset
    }

    /// Release only idle cache references. Native playback owners remain
    /// valid until their engines are stopped and destroyed.
    public func purge() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        bytes = 0
    }
}
