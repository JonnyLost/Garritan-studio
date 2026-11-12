import Foundation

/// A wet-only, per-instrument early-reflection processor.
///
/// Inputs are stereo noninterleaved Float32; one mono delay buffer is used
/// because room position is encoded in separately delayed stereo taps. Each
/// instrument owns one instance, while its late tail remains shared by the
/// entire orchestra. Buffers and tap capacity are allocated at initialization.
///
/// The reflective geometry is a useful perceptual approximation, NOT a ray
/// tracer or a measurement of the referenced scoring rooms.
public final class NativeStageEarlyReflectionProcessor {
    private struct SourceTap {
        let delayFrames: Int
        let leftGain: Float
        let rightGain: Float
    }

    private struct RenderTap {
        var leftOffset = 1
        var rightOffset = 1
        var leftGain: Float = 0
        var rightGain: Float = 0
    }

    private let sampleRate: Double
    private let samples: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writePosition = 0

    private let roomTaps: [[SourceTap]]
    private var renderTaps = [RenderTap](repeating: RenderTap(), count: 32)
    private var tapCount = -1

    public private(set) var roomIndex = 0
    public private(set) var pan: Float = 0
    public private(set) var zone: Int = 2

    public init(sampleRate: Double,
                profiles: [StudioRoomAcousticProfile] = StudioRoomAcousticProfile.starterProfiles) {
        let rate = sampleRate.isFinite && (8_000...192_000).contains(sampleRate)
            ? sampleRate : 48_000
        self.sampleRate = rate
        // Maximum stored profile reflection: 120 ms. Geometric offsets can
        // contribute another 12 ms. At 48 kHz this uses about 26 KB/track.
        capacity = Int((rate * 0.134).rounded(.up)) + 2
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)

        let selected = profiles.isEmpty ? [StudioRoomAcousticProfile.abbeyRoadStudioOne] : profiles
        roomTaps = selected.map { profile in
            profile.earlyReflections.prefix(32).compactMap { tap -> SourceTap? in
                guard tap.delayMilliseconds.isFinite, tap.delayMilliseconds >= 0,
                      tap.leftGain.isFinite, tap.rightGain.isFinite else { return nil }
                return SourceTap(
                    delayFrames: Int((min(120, Double(tap.delayMilliseconds)) * rate / 1_000).rounded()),
                    leftGain: min(1, max(-1, tap.leftGain)),
                    rightGain: min(1, max(-1, tap.rightGain))
                )
            }
        }
        update(roomIndex: 0, pan: 0, zone: 2)
    }

    deinit {
        samples.deinitialize(count: capacity)
        samples.deallocate()
    }

    /// Called only by the owning render thread (e.g. once per AU render
    /// block). No allocation, locking, sample-buffer reset, or exponentials.
    public func update(roomIndex: Int, pan: Float, zone: Int) {
        let resolvedIndex = roomTaps.indices.contains(roomIndex) ? roomIndex : 0
        let resolvedPan = pan.isFinite ? min(1, max(-1, pan)) : 0
        let resolvedZone = min(5, max(0, zone))
        guard self.roomIndex != resolvedIndex ||
              self.pan != resolvedPan ||
              self.zone != resolvedZone || tapCount < 0 else { return }

        self.roomIndex = resolvedIndex
        self.pan = resolvedPan
        self.zone = resolvedZone

        // Zone zero intentionally has no reflections: conductor/dry.
        guard resolvedZone > 0 else { tapCount = 0; return }

        let taps = roomTaps[resolvedIndex]
        tapCount = taps.count
        let depthFrames = Int((Double(resolvedZone - 1) * sampleRate * 0.0015).rounded())
        let lateralFrames = Int((Double(resolvedPan) * sampleRate * 0.0035).rounded())
        // More distant positions have slightly later/more diffuse reflections;
        // the overall hall-send gain is still owned by TrackAudioNode.
        let distanceGain: Float = 1.0 - Float(resolvedZone - 1) * 0.055

        for i in 0..<tapCount {
            let tap = taps[i]
            let offset = tap.delayFrames + depthFrames
            renderTaps[i].leftOffset = min(capacity - 1, max(1, offset + lateralFrames))
            renderTaps[i].rightOffset = min(capacity - 1, max(1, offset - lateralFrames))
            renderTaps[i].leftGain = tap.leftGain * distanceGain * (1 - 0.25 * resolvedPan)
            renderTaps[i].rightGain = tap.rightGain * distanceGain * (1 + 0.25 * resolvedPan)
        }
    }

    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>,
                        frameCount: Int) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let input = (left[frame] + right[frame]) * 0.5
            samples[writePosition] = input
            var reflectedL: Float = 0
            var reflectedR: Float = 0
            for i in 0..<tapCount {
                let tap = renderTaps[i]
                var leftIndex = writePosition - tap.leftOffset
                if leftIndex < 0 { leftIndex += capacity }
                var rightIndex = writePosition - tap.rightOffset
                if rightIndex < 0 { rightIndex += capacity }
                reflectedL += samples[leftIndex] * tap.leftGain
                reflectedR += samples[rightIndex] * tap.rightGain
            }
            writePosition += 1
            if writePosition == capacity { writePosition = 0 }

            // Wet-only output, pre-send gain comes from the track's mixer.
            left[frame] = 0.50 * reflectedL
            right[frame] = 0.50 * reflectedR
        }
    }
}
