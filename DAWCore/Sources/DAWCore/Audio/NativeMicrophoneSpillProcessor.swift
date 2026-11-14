import Foundation

/// One source -> one microphone direct/bleed path. The host prepares one
/// instance per enabled pair, outside AVAudioEngine's render callback.
/// Receive stereo source audio BEFORE the legacy track panner; render a
/// single idealized capsule, then let the mic mixer's pan place it in stereo.
/// 
/// This is a delay/directivity/air-loss approximation, NOT a measured
/// microphone impulse response. One shared room return remains elsewhere.
public final class NativeMicrophoneSpillProcessor {
    public static let maximumDelayMilliseconds: Float = 450

    private let history: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var position = 0
    private let sampleRate: Float
    private let smoothing: Float
    private var currentGain: Float = 0
    private var targetGain: Float = 0
    private var currentDelayFrames: Float = 0
    private var targetDelayFrames: Float = 0
    private var currentLowPassAlpha: Float = 1
    private var targetLowPassAlpha: Float = 1
    private var lowPassState: Float = 0
    private var preparedFirstTargets = false

    public init(sampleRate: Double) {
        let rate = sampleRate.isFinite && (8_000...192_000).contains(sampleRate)
            ? sampleRate : 48_000
        self.sampleRate = Float(rate)
        self.smoothing = Float(1 - exp(-1 / (0.025 * rate)))
        self.capacity = Int((rate * 0.452).rounded(.up)) + 4
        history = .allocate(capacity: capacity)
        history.initialize(repeating: 0, count: capacity)
    }

    deinit {
        history.deinitialize(count: capacity)
        history.deallocate()
    }

    /// Render-thread scalar parameter update. Filter and source geometry
    /// are calculated in AudioEngine beforehand; no exponentials here.
    public func setTargets(gain: Float, delayMilliseconds: Float,
                           lowPassAlpha: Float) {
        targetGain = gain.isFinite ? min(2, max(-2, gain)) : 0
        let safeDelay = delayMilliseconds.isFinite
            ? min(Self.maximumDelayMilliseconds, max(0, delayMilliseconds)) : 0
        targetDelayFrames = safeDelay * sampleRate / 1_000
        targetLowPassAlpha = lowPassAlpha.isFinite
            ? min(1, max(0.00001, lowPassAlpha)) : 1
        if !preparedFirstTargets {
            // The first sound must arrive at the actual propagation delay.
            // Starting the smoothing filter at zero would produce an
            // unphysical early sound burst before a distant microphone's
            // first reflection arrives.
            currentGain = targetGain
            currentDelayFrames = targetDelayFrames
            currentLowPassAlpha = targetLowPassAlpha
            preparedFirstTargets = true
        }
    }

    /// In-place, deinterleaved Float32 stereo buffer, no allocation or lock.
    /// Input is folded to mono as one physical microphone capsule. Stereo
    /// localization belongs to the independent microphone channel mixer.
    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let mono = (left[frame] + right[frame]) * 0.5
            history[position] = mono

            currentGain += smoothing * (targetGain - currentGain)
            currentDelayFrames += smoothing * (targetDelayFrames - currentDelayFrames)
            currentLowPassAlpha += smoothing *
                (targetLowPassAlpha - currentLowPassAlpha)

            let offset = Int(currentDelayFrames)
            let fraction = currentDelayFrames - Float(offset)
            var read = position - offset
            if read < 0 { read += capacity }
            var previous = read - 1
            if previous < 0 { previous += capacity }
            let delayed = history[read] * (1 - fraction) +
                history[previous] * fraction
            lowPassState += currentLowPassAlpha * (delayed - lowPassState)
            let result = lowPassState * currentGain
            left[frame] = result
            right[frame] = result

            position += 1
            if position == capacity { position = 0 }
        }
    }
}
