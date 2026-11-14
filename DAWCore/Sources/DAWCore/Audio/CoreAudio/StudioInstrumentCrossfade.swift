import Foundation

/// A short, linear dry-signal crossfade. The shared effect chain runs only
/// once AFTER this blend, so a large orchestral routing stack is not
/// duplicated during a patch change. All buffers are preallocated.
enum StudioInstrumentCrossfade {
    @inline(__always)
    static func blend(
        oldLeft: UnsafePointer<Float>,
        oldRight: UnsafePointer<Float>,
        newLeft: UnsafeMutablePointer<Float>,
        newRight: UnsafeMutablePointer<Float>,
        frames: Int,
        startFrame: UInt32,
        totalFrames: UInt32
    ) {
        guard frames > 0, totalFrames > 0 else { return }
        let reciprocal = 1.0 / Float(totalFrames)
        for index in 0..<frames {
            let elapsed = UInt64(startFrame) + UInt64(index)
            let newGain = min(1, Float(elapsed) * reciprocal)
            let oldGain = 1 - newGain
            newLeft[index] = oldLeft[index] * oldGain + newLeft[index] * newGain
            newRight[index] = oldRight[index] * oldGain + newRight[index] * newGain
        }
    }
}
