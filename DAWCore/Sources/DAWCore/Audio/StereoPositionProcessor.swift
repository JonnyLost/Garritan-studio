import Foundation

/// Library-independent stereo-image positioning DSP.
///
/// This is the render kernel, not yet an Audio Unit. It performs no allocations,
/// locking, logging, or UI work while processing. The host must supply two
/// noninterleaved Float32 channels and serialize access to this instance.
///
/// Unlike AVAudioMixerNode.pan (stereo balance), moving fully left folds both
/// source channels into the left output. Center is an exact passthrough.
public struct StereoPositionProcessor {
    /// -1 = left, 0 = unchanged stereo, +1 = right.
    public private(set) var pan: Float = 0

    /// Change the target position. The next buffer smoothly ramps from the
    /// previous position, avoiding a hard gain discontinuity at its boundary.
    public mutating func setPan(_ value: Float) {
        pan = value.isFinite ? min(1, max(-1, value)) : 0
    }

    private var renderedPan: Float = 0

    public init(pan: Float = 0) {
        let clamped = pan.isFinite ? min(1, max(-1, pan)) : 0
        self.pan = clamped
        self.renderedPan = clamped
    }

    /// In-place stereo processing. No allocation; supports a zero-frame buffer.
    /// Inputs must be distinct writable buffers of at least frameCount samples.
    ///
    /// At either extreme, (L+R)/2 prevents coherent stereo sources from
    /// summing above their original peak. Intermediate positions retain part
    /// of the original stereo image rather than dropping the opposite channel.
    public mutating func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let start = renderedPan
        let increment = (pan - start) / Float(frameCount)
        for frame in 0..<frameCount {
            let position = start + increment * Float(frame + 1)
            let l = left[frame]
            let r = right[frame]
            if position < 0 {
                let amount = -position
                left[frame] = l * (1 - amount) + (l + r) * (0.5 * amount)
                right[frame] = r * (1 - amount)
            } else if position > 0 {
                let amount = position
                left[frame] = l * (1 - amount)
                right[frame] = r * (1 - amount) + (l + r) * (0.5 * amount)
            }
        }
        renderedPan = pan
    }

    /// For testing and explicit resets, jump to a position without ramping.
    public mutating func reset(pan value: Float = 0) {
        setPan(value)
        renderedPan = pan
    }
}
