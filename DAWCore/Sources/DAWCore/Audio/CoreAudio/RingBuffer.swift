import Foundation
import DAWRealtime

// MARK: - Ring Buffer

/// Lock-free single-producer single-consumer ring buffer
/// Used for realtime-safe communication between main thread and audio thread
///
/// Design:
/// - Main thread (producer) writes events via `push()`
/// - Audio thread (consumer) reads events via `peek()` and `pop()`
/// - No locks, no allocations on audio thread
/// - Power-of-2 capacity for efficient masking
public final class RingBuffer<T> {
    
    // MARK: - Properties
    
    /// The backing storage
    private let buffer: UnsafeMutablePointer<T?>
    
    /// Capacity (always power of 2)
    private let capacity: Int
    
    /// Bitmask for efficient modulo (capacity - 1)
    private let cursor: OpaquePointer
    
    // MARK: - Initialization
    
    /// Create a ring buffer with the specified minimum capacity
    /// Actual capacity will be rounded up to the next power of 2
    public init(capacity: Int) {
        let clamped = max(2, min(capacity, 1 << 29))
        let actualCapacity = Self.nextPowerOf2(clamped)
        self.capacity = actualCapacity
        guard let cursor = daw_spsc_cursor_create(UInt32(actualCapacity)) else {
            preconditionFailure("Unable to allocate atomic SPSC cursor")
        }
        self.cursor = cursor
        
        // Allocate and initialize buffer
        self.buffer = UnsafeMutablePointer<T?>.allocate(capacity: actualCapacity)
        self.buffer.initialize(repeating: nil, count: actualCapacity)
    }
    
    deinit {
        // Clean up
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
        daw_spsc_cursor_destroy(cursor)
    }
    
    // MARK: - Producer Methods (Main Thread)
    
    /// Push an element to the buffer
    /// - Parameter element: The element to push
    /// - Returns: true if successful, false if buffer is full
    /// - Note: Only call from producer (main) thread
    @discardableResult
    public func push(_ element: T) -> Bool {
        let slot = daw_spsc_write_index(cursor)
        guard slot != UInt32.max else { return false }
        buffer[Int(slot)] = element
        daw_spsc_commit_write(cursor)
        return true
    }

    @discardableResult
    public func push(contentsOf elements: [T]) -> Int {
        var pushed = 0
        for element in elements {
            guard push(element) else { break }
            pushed += 1
        }
        return pushed
    }

    /// Consumer-only; the acquired index guarantees the producer published
    /// the fully written event before the audio thread reads it.
    public func peek() -> T? {
        let slot = daw_spsc_read_index(cursor)
        guard slot != UInt32.max else { return nil }
        return buffer[Int(slot)]
    }

    /// Consumer-only. Do not overwrite a slot until ownership is released.
    public func pop() {
        let slot = daw_spsc_read_index(cursor)
        guard slot != UInt32.max else { return }
        buffer[Int(slot)] = nil
        daw_spsc_commit_read(cursor)
    }

    public func popAndReturn() -> T? {
        guard let element = peek() else { return nil }
        pop()
        return element
    }

    public var isEmpty: Bool { daw_spsc_count(cursor) == 0 }
    public var count: Int { Int(daw_spsc_count(cursor)) }
    public var availableSpace: Int { capacity - 1 - count }

    /// Requires the producer and render consumer both to be stopped.
    public func clear() {
        // Do not release slots from a third thread while the callback reads.
        daw_spsc_clear_quiescent(cursor)
    }

    /// Requires the producer and render consumer both to be stopped.
    public func reset() {
        daw_spsc_reset_quiescent(cursor)
        for i in 0..<capacity { buffer[i] = nil }
    }

    // MARK: - Helpers
    
    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v += 1
        return v
    }
}

// MARK: - Specialized Ring Buffer for MIDI Events

/// A ring buffer specifically optimized for MIDI events
/// Pre-sorted by sample position for efficient processing
public final class MIDIEventRingBuffer {
    
    private let buffer: RingBuffer<ScheduledMIDIEvent>
    
    public init(capacity: Int = 16384) {
        self.buffer = RingBuffer(capacity: capacity)
    }
    
    /// Schedule a MIDI event
    @discardableResult
    public func schedule(_ event: ScheduledMIDIEvent) -> Bool {
        buffer.push(event)
    }
    
    /// Schedule multiple events (should be pre-sorted by sample position)
    @discardableResult
    public func schedule(contentsOf events: [ScheduledMIDIEvent]) -> Int {
        buffer.push(contentsOf: events)
    }
    
    /// Get the next event if it falls within the sample range
    /// - Parameters:
    ///   - startSample: Start of the buffer range
    ///   - endSample: End of the buffer range
    /// - Returns: The event if it's in range, nil otherwise
    public func peekIfInRange(startSample: Int64, endSample: Int64) -> ScheduledMIDIEvent? {
        // An edit or seek can leave thousands of stale events in the queue.
        // Discard them iteratively: recursive calls could overflow the audio
        // render thread's limited stack.
        while let event = buffer.peek() {
            if event.samplePosition < startSample {
                buffer.pop()
                continue
            }
            if event.samplePosition >= endSample {
                return nil
            }
            return event
        }
        return nil
    }
    
    /// Pop the current event
    public func pop() {
        buffer.pop()
    }
    
    /// Clear all events
    public func clear() {
        buffer.clear()
    }
    
    public var isEmpty: Bool {
        buffer.isEmpty
    }
    
    public var count: Int {
        buffer.count
    }
}

// MARK: - Audio Buffer Pool

/// A pool of pre-allocated audio buffers for realtime use
/// Avoids allocation on the audio thread
public final class AudioBufferPool {
    
    private var availableBuffers: [UnsafeMutablePointer<Float>] = []
    private let bufferSize: Int
    private let lock = NSLock()
    
    public init(bufferCount: Int, bufferSize: Int) {
        self.bufferSize = bufferSize
        
        // Pre-allocate buffers
        for _ in 0..<bufferCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
            buffer.initialize(repeating: 0, count: bufferSize)
            availableBuffers.append(buffer)
        }
    }
    
    deinit {
        for buffer in availableBuffers {
            buffer.deinitialize(count: bufferSize)
            buffer.deallocate()
        }
    }
    
    /// Acquire a buffer from the pool
    /// - Warning: For offline use only, not realtime safe due to lock
    public func acquire() -> UnsafeMutablePointer<Float>? {
        lock.lock()
        defer { lock.unlock() }
        return availableBuffers.popLast()
    }
    
    /// Return a buffer to the pool
    /// - Warning: For offline use only, not realtime safe due to lock
    public func release(_ buffer: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        
        // Zero the buffer before returning
        buffer.initialize(repeating: 0, count: bufferSize)
        availableBuffers.append(buffer)
    }
}
