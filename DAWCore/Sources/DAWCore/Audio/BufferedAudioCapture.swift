import Foundation
import AVFoundation
import DAWRealtime

/// A stereo capture handoff: the AVAudioEngine tap only copies Float32 frames
/// into a bounded, preallocated SPSC ring. File I/O, downsampling, and UI
/// progress happen on a separate serial queue. One tap is the sole producer.
final class BufferedAudioCapture: @unchecked Sendable {
    struct Progress {
        let writtenFrames: Int64
        let peak: Float
        let waveformPoints: [Float]
    }

    struct Completion {
        let writtenFrames: Int64
        let droppedFrames: UInt64
        let writeError: String?

        var succeeded: Bool { droppedFrames == 0 && writeError == nil }
    }

    enum CaptureError: Error {
        case allocationFailed
        case invalidSampleRate
    }

    private let ring: OpaquePointer
    private let file: AVAudioFile
    private let writerQueue = DispatchQueue(label: "com.garritan.studio.capture-writer", qos: .userInitiated)
    private let writerFormat: AVAudioFormat
    private let writerBuffer: AVAudioPCMBuffer
    private var interleavedScratch = [Float](repeating: 0, count: 8192)
    private var timer: DispatchSourceTimer?
    // The following fields are accessed exclusively by writerQueue.
    private var writtenFrames: Int64 = 0
    private var writeError: String?
    private var waveformAccumulator: Float = 0
    private var waveformFrameCount: Int = 0
    private var pendingWaveform: [Float] = []

    init(file: AVAudioFile, sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw CaptureError.invalidSampleRate
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw CaptureError.allocationFailed
        }
        // At least ~4 seconds of 48-kHz stereo capture to absorb brief disk
        // stalls. Capacity is rounded up to a power of two in DAWRealtime.
        let capacity = UInt32(min(524_288, max(131_072, Int(sampleRate * 4))))
        guard let ring = daw_audio_ring_create(capacity) else {
            throw CaptureError.allocationFailed
        }
        self.ring = ring
        self.file = file
        self.writerFormat = format
        self.writerBuffer = buffer

        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        self.timer = timer
        timer.resume()
    }

    /// Audio render callback: no locks, task creation, buffer allocation,
    /// SwiftUI state updates, disk access, or blocking cross-thread calls.
    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = UInt32(buffer.frameLength)
        guard frames > 0 else { return }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else {
            daw_audio_ring_mark_dropped(ring, frames)
            return
        }
        let channels = UInt32(buffer.format.channelCount)
        let isInterleaved = buffer.format.isInterleaved
        let second = (!isInterleaved && channels > 1) ? data[1] : data[0]
        _ = daw_audio_ring_push(
            ring, data[0], second, channels, frames, isInterleaved
        )
    }

    /// Async, non-blocking UI progress query. The caller's completion is
    /// delivered on the main queue; it must be inexpensive.
    func requestProgress(_ completion: @escaping (Progress) -> Void) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            let points = self.pendingWaveform
            self.pendingWaveform.removeAll(keepingCapacity: true)
            let progress = Progress(
                writtenFrames: self.writtenFrames,
                peak: daw_audio_ring_take_peak(self.ring),
                waveformPoints: points
            )
            DispatchQueue.main.async {
                completion(progress)
            }
        }
    }

    /// Call only after removing the input tap. Drain any remaining buffers
    /// before closing the writer and returning the file's true frame count.
    func finish() -> Completion {
        timer?.cancel()
        timer = nil
        return writerQueue.sync {
            drain()
            return Completion(
                writtenFrames: writtenFrames,
                droppedFrames: daw_audio_ring_dropped_frames(ring),
                writeError: writeError
            )
        }
    }

    deinit {
        timer?.cancel()
        daw_audio_ring_destroy(ring)
    }

    private func drain() {
        while true {
            let count = interleavedScratch.withUnsafeMutableBufferPointer { scratch in
                daw_audio_ring_pop(ring, scratch.baseAddress, UInt32(scratch.count / 2))
            }
            guard count > 0 else { return }
            let frames = Int(count)
            writerBuffer.frameLength = AVAudioFrameCount(count)
            guard let channels = writerBuffer.floatChannelData else {
                writeError = "Float32 recording buffer unavailable"
                return
            }
            for frame in 0..<frames {
                let left = interleavedScratch[frame * 2]
                let right = interleavedScratch[frame * 2 + 1]
                channels[0][frame] = left
                channels[1][frame] = right
                waveformAccumulator = max(waveformAccumulator, max(abs(left), abs(right)))
                waveformFrameCount += 1
                if waveformFrameCount >= 512 {
                    pendingWaveform.append(waveformAccumulator)
                    waveformAccumulator = 0
                    waveformFrameCount = 0
                }
            }
            if pendingWaveform.count > 4096 {
                pendingWaveform.removeFirst(pendingWaveform.count - 4096)
            }
            // AVAudioFile is only accessed on the writer queue, never in tap.
            if writeError == nil {
                do {
                    try file.write(from: writerBuffer)
                    writtenFrames += Int64(count)
                } catch {
                    writeError = String(describing: error)
                }
            }
        }
    }
}

/// Peak metering used when a track is armed but not recording.
final class RealtimePeakMeter: @unchecked Sendable {
    private let meter: OpaquePointer

    init?() {
        guard let pointer = daw_audio_peak_meter_create() else { return nil }
        meter = pointer
    }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else { return }
        let channels = UInt32(buffer.format.channelCount)
        let second = (!buffer.format.isInterleaved && channels > 1) ? data[1] : data[0]
        daw_audio_peak_meter_measure(
            meter, data[0], second, channels,
            UInt32(buffer.frameLength), buffer.format.isInterleaved
        )
    }

    func takePeak() -> Float {
        daw_audio_peak_meter_take(meter)
    }

    deinit {
        daw_audio_peak_meter_destroy(meter)
    }
}

/// Stereo meter state can be shared with an audio tap, and polled on the
/// main actor at a controlled rate instead of dispatching once per buffer.
final class RealtimeStereoPeakMeter: @unchecked Sendable {
    private let meter: OpaquePointer

    init?() {
        guard let pointer = daw_audio_stereo_meter_create() else { return nil }
        meter = pointer
    }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else { return }
        let channels = UInt32(buffer.format.channelCount)
        let second = (!buffer.format.isInterleaved && channels > 1) ? data[1] : data[0]
        daw_audio_stereo_meter_measure(
            meter, data[0], second, channels,
            UInt32(buffer.frameLength), buffer.format.isInterleaved
        )
    }

    func takePeaks() -> (left: Float, right: Float) {
        var left: Float = 0
        var right: Float = 0
        daw_audio_stereo_meter_take(meter, &left, &right)
        return (left, right)
    }

    deinit {
        daw_audio_stereo_meter_destroy(meter)
    }
}
