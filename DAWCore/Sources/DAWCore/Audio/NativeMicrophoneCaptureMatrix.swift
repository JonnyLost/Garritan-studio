import Foundation

/// Shared-history virtual microphone DSP. This is the preallocated rendering
/// core for a future consolidated Audio Unit, not yet installed in AVAudioEngine.
///
/// A source's mono history is stored ONCE, irrespective of microphone count.
/// Each (source, capsule) pair retains its own gain, fractional propagation
/// delay and air-loss filter state. Inputs and outputs are supplied by the host;
/// render() performs no allocation, locking or graph mutation.
///
/// All setPath calls must be serialized with rendering by the host. In a live
/// Audio Unit, UI parameters will need an explicit render-thread handoff.
public final class NativeMicrophoneCaptureMatrix {
    public struct Source {
        public let left: UnsafePointer<Float>
        public let right: UnsafePointer<Float>

        public init(left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
            self.left = left
            self.right = right
        }
    }

    public static let maximumSources = 64
    public static let maximumMicrophones = 4
    public static let maximumDelayMilliseconds: Float = 450

    private struct Path {
        var targetGain: Float = 0
        var targetDelay: Float = 0
        var targetAlpha: Float = 1
        var gain: Float = 0
        var delay: Float = 0
        var alpha: Float = 1
        var filtered: Float = 0
        var prepared = false
    }

    public let sourceCount: Int
    public let microphoneCount: Int
    private let rate: Float
    private let capacity: Int
    private let smoothing: Float
    private let history: UnsafeMutablePointer<Float>
    private var writePosition = 0
    private var paths: [Path]

    public init?(sampleRate: Double, sources: Int, microphones: Int) {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (1...Self.maximumSources).contains(sources),
              (1...Self.maximumMicrophones).contains(microphones)
        else { return nil }
        sourceCount = sources
        microphoneCount = microphones
        rate = Float(sampleRate)
        capacity = Int(ceil(sampleRate * 0.452)) + 4
        smoothing = Float(1 - exp(-1 / (0.025 * sampleRate)))
        history = .allocate(capacity: capacity * sources)
        history.initialize(repeating: 0, count: capacity * sources)
        paths = Array(repeating: Path(), count: sources * microphones)
    }

    deinit {
        history.deinitialize(count: capacity * sourceCount)
        history.deallocate()
    }

    /// The microphone index is the fast-moving dimension.
    /// The first set establishes the physical delay immediately: no early
    /// transient at the listener. Subsequent edits are smoothly interpolated.
    @discardableResult
    public func setPath(source: Int, microphone: Int, gain: Float,
                        delayMilliseconds: Float, lowPassAlpha: Float) -> Bool {
        guard (0..<sourceCount).contains(source),
              (0..<microphoneCount).contains(microphone) else { return false }
        let index = source * microphoneCount + microphone
        let safeGain = gain.isFinite ? min(2, max(-2, gain)) : 0
        let ms = delayMilliseconds.isFinite
            ? min(Self.maximumDelayMilliseconds, max(0, delayMilliseconds)) : 0
        let alpha = lowPassAlpha.isFinite
            ? min(1, max(0.00001, lowPassAlpha)) : 1
        paths[index].targetGain = safeGain
        paths[index].targetDelay = ms * rate / 1_000
        paths[index].targetAlpha = alpha
        if !paths[index].prepared {
            paths[index].gain = safeGain
            paths[index].delay = paths[index].targetDelay
            paths[index].alpha = alpha
            paths[index].prepared = true
        }
        return true
    }

    /// Render the exact number of configured inputs and microphone outputs.
    /// Output arrays are overwritten, never added to an unknown destination.
    /// Invalid cardinalities cause a no-op, not an unsafe partial mix.
    @discardableResult
    public func render(sources: [Source], outputs: [UnsafeMutablePointer<Float>],
                       frameCount: Int) -> Bool {
        guard sources.count == sourceCount,
              outputs.count == microphoneCount,
              frameCount >= 0 else { return false }
        guard frameCount > 0 else { return true }

        for frame in 0..<frameCount {
            for mic in 0..<microphoneCount { outputs[mic][frame] = 0 }
            for source in 0..<sourceCount {
                let input = sources[source]
                let left = input.left[frame]
                let right = input.right[frame]
                let mono = (left.isFinite && right.isFinite)
                    ? 0.5 * (left + right) : 0
                let base = source * capacity
                history[base + writePosition] = mono.isFinite ? mono : 0

                for mic in 0..<microphoneCount {
                    let index = source * microphoneCount + mic
                    paths[index].gain += smoothing *
                        (paths[index].targetGain - paths[index].gain)
                    paths[index].delay += smoothing *
                        (paths[index].targetDelay - paths[index].delay)
                    paths[index].alpha += smoothing *
                        (paths[index].targetAlpha - paths[index].alpha)

                    let offset = Int(paths[index].delay)
                    let fraction = paths[index].delay - Float(offset)
                    var read = writePosition - offset
                    if read < 0 { read += capacity }
                    var previous = read - 1
                    if previous < 0 { previous += capacity }
                    let delayed = history[base + read] * (1 - fraction) +
                        history[base + previous] * fraction
                    paths[index].filtered += paths[index].alpha *
                        (delayed - paths[index].filtered)
                    let contribution = paths[index].filtered * paths[index].gain
                    if contribution.isFinite {
                        outputs[mic][frame] += contribution
                    }
                }
            }
            writePosition += 1
            if writePosition == capacity { writePosition = 0 }
        }
        return true
    }

    /// The shared mono history occupies sourceCount * capacity samples,
    /// compared with sourceCount * microphoneCount * capacity for the
    /// original independent pair processors.
    public var historySampleCount: Int { sourceCount * capacity }
}
