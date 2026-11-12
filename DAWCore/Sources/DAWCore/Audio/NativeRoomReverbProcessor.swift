import Foundation

/// Fully original, wet-only reverb kernel: sparse stereo early reflections plus
/// a 16-line orthogonal feedback delay network with three-band decay control.
///
/// Create or replace off the audio thread. The process method performs no
/// heap allocation, locking, logging or file I/O. One render thread owns each
/// processor instance, and the caller supplies two distinct noninterleaved
/// Float32 buffers. Do not modify the processor from the UI thread mid-render.
public final class NativeRoomReverbProcessor {
    private final class DelayLine {
        private struct DecayGains {
            let bass: Float
            let mid: Float
            let treble: Float
        }

        private let storage: UnsafeMutablePointer<Float>
        private let count: Int
        private var position = 0
        private var lowState: Float = 0
        private var highState: Float = 0
        private let lowCoefficient: Float
        private let highCoefficient: Float
        private let presetGains: [DecayGains]
        private var bassGain: Float
        private var midGain: Float
        private var trebleGain: Float

        init(frames: Int, sampleRate: Double, profiles: [StudioRoomAcousticProfile]) {
            count = max(2, frames)
            let delayFrameCount = Float(max(2, frames))
            storage = .allocate(capacity: count)
            storage.initialize(repeating: 0, count: count)
            lowCoefficient = Float(1 - exp(-2 * Double.pi * 250 / sampleRate))
            highCoefficient = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))
            func gain(_ seconds: Float) -> Float {
                let safe = seconds.isFinite ? max(0.2, min(15, seconds)) : 2
                return pow(10, -3 * delayFrameCount / (Float(sampleRate) * safe))
            }
            let all = profiles.map { profile in
                DecayGains(
                    bass: gain(profile.bassRT60),
                    mid: gain(profile.midRT60),
                    treble: gain(profile.trebleRT60)
                )
            }
            presetGains = all
            bassGain = all[0].bass
            midGain = all[0].mid
            trebleGain = all[0].treble
        }

        /// Coefficients are prepared before rendering. Switching performs no
        /// exp/pow, allocation, locking or reverb-state reset on the audio thread.
        @inline(__always) func selectProfile(at index: Int) {
            let gains = presetGains[index]
            bassGain = gains.bass
            midGain = gains.mid
            trebleGain = gains.treble
        }

        deinit {
            storage.deinitialize(count: count)
            storage.deallocate()
        }

        /// Read feedback sample at the current position and apply band decays.
        @inline(__always) func readDamped() -> Float {
            let sample = storage[position]
            lowState += lowCoefficient * (sample - lowState)
            highState += highCoefficient * (sample - highState)
            let bass = lowState
            let mid = highState - lowState
            let treble = sample - highState
            return bass * bassGain + mid * midGain + treble * trebleGain
        }

        @inline(__always) func write(_ sample: Float) {
            storage[position] = sample
            position += 1
            if position == count { position = 0 }
        }
    }

    private struct ReflectionTap {
        let offset: Int
        let leftGain: Float
        let rightGain: Float
    }

    private static let delaysMilliseconds: [Double] = [
        29.7, 33.1, 36.7, 40.9, 44.3, 48.1, 52.7, 57.1,
        61.3, 65.9, 70.1, 74.9, 80.3, 85.1, 91.1, 97.7
    ]
    private let lines: [DelayLine]
    private var network = [Float](repeating: 0, count: 16)
    private let presetReflections: [[ReflectionTap]]
    public private(set) var selectedProfileIndex = 0
    private let earlyLeft: UnsafeMutablePointer<Float>
    private let earlyRight: UnsafeMutablePointer<Float>
    private let earlyLength: Int
    private var earlyPosition = 0

    /// Standalone initializer retained for existing DSP tests and callers.
    public convenience init(sampleRate: Double,
                            profile: StudioRoomAcousticProfile = .abbeyRoadStudioOne) {
        self.init(sampleRate: sampleRate, profiles: [profile])
    }

    /// Profiles and all delay/filter coefficients are prepared off the audio thread.
    public init(sampleRate: Double, profiles: [StudioRoomAcousticProfile],
                includeEarlyReflections: Bool = true) {
        let rate = sampleRate.isFinite && (8_000...192_000).contains(sampleRate)
            ? sampleRate : 48_000
        let selected = profiles.isEmpty ? [StudioRoomAcousticProfile.abbeyRoadStudioOne] : profiles
        lines = Self.delaysMilliseconds.map { ms in
            DelayLine(frames: Int((ms * rate / 1000).rounded()),
                      sampleRate: rate, profiles: selected)
        }
        presetReflections = selected.map { profile in
            // In the AVAudioEngine, a distinct per-track sidechain owns
            // source-positioned early reflections. Prevent a doubled ER field.
            (includeEarlyReflections ? profile.earlyReflections : []).prefix(32)
                .compactMap { tap -> ReflectionTap? in
                guard tap.delayMilliseconds.isFinite, tap.delayMilliseconds >= 0,
                      tap.leftGain.isFinite, tap.rightGain.isFinite else { return nil }
                let offset = Int((Double(min(200, tap.delayMilliseconds)) * rate / 1000).rounded())
                return ReflectionTap(offset: offset,
                                     leftGain: min(1, max(-1, tap.leftGain)),
                                     rightGain: min(1, max(-1, tap.rightGain)))
            }
        }
        earlyLength = max(2, (presetReflections.flatMap { $0 }.map(\.offset).max() ?? 0) + 1)
        earlyLeft = .allocate(capacity: earlyLength)
        earlyRight = .allocate(capacity: earlyLength)
        earlyLeft.initialize(repeating: 0, count: earlyLength)
        earlyRight.initialize(repeating: 0, count: earlyLength)
    }

    /// Must be invoked from the owning render thread, never concurrently with
    /// process(). Preserves the current FDN tail across profile changes.
    public func selectProfile(at index: Int) {
        guard presetReflections.indices.contains(index),
              selectedProfileIndex != index else { return }
        selectedProfileIndex = index
        for line in lines { line.selectProfile(at: index) }
    }

    deinit {
        earlyLeft.deinitialize(count: earlyLength)
        earlyRight.deinitialize(count: earlyLength)
        earlyLeft.deallocate()
        earlyRight.deallocate()
    }

    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let reflections = presetReflections[selectedProfileIndex]
        for frame in 0..<frameCount {
            let inputLeft = left[frame]
            let inputRight = right[frame]
            let mono = 0.5 * (inputLeft + inputRight)

            earlyLeft[earlyPosition] = inputLeft
            earlyRight[earlyPosition] = inputRight
            var earlyOutLeft: Float = 0
            var earlyOutRight: Float = 0
            for tap in reflections {
                let read = (earlyPosition + earlyLength - tap.offset) % earlyLength
                let reflected = 0.5 * (earlyLeft[read] + earlyRight[read])
                earlyOutLeft += reflected * tap.leftGain
                earlyOutRight += reflected * tap.rightGain
            }
            earlyPosition += 1
            if earlyPosition == earlyLength { earlyPosition = 0 }

            var tailLeft: Float = 0
            var tailRight: Float = 0
            for index in 0..<16 {
                let value = lines[index].readDamped()
                network[index] = value
                tailLeft += value * ((index & 1) == 0 ? 1 : -1)
                tailRight += value * ((index & 2) == 0 ? 1 : -1)
            }

            // In-place Walsh-Hadamard transform, scaled by 1/sqrt(16) = 0.25.
            // This orthogonal mix does not amplify feedback-loop energy.
            var span = 1
            while span < 16 {
                var start = 0
                while start < 16 {
                    for index in start..<(start + span) {
                        let a = network[index]
                        let b = network[index + span]
                        network[index] = a + b
                        network[index + span] = a - b
                    }
                    start += 2 * span
                }
                span *= 2
            }
            for index in 0..<16 {
                let injection: Float = ((index & 4) == 0 ? 0.13 : -0.13) * mono
                lines[index].write(network[index] * 0.25 + injection)
            }
            left[frame] = 0.50 * earlyOutLeft + 0.12 * tailLeft
            right[frame] = 0.50 * earlyOutRight + 0.12 * tailRight
        }
    }
}
