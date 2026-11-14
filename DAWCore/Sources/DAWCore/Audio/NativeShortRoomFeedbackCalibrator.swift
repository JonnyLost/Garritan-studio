import Foundation

/// Offline-precomputed feedback gains for strongly damped six-band custom
/// rooms. This does NOT measure a room, replace Studio's FDN, or run on a
/// render thread. It fits the actual first-order complementary split filter's
/// magnitude response at octave centers rather than assuming the six
/// channel gains are acoustically independent.
///
/// Deliberately conservative: bounded gains (<1), regularization towards
/// original coefficients, fixed iteration budget, and *only* opt-in on
/// short-decay custom rooms. Preserve historical rooms exactly.
enum NativeShortRoomFeedbackCalibrator {
    static let centersHz: [Double] = [125, 250, 500, 1_000, 2_000, 4_000]
    private static let crossoverHz: [Double] = [177, 354, 707, 1_414, 2_828]

    struct Complex {
        var re: Double
        var im: Double

        static func + (a: Complex, b: Complex) -> Complex {
            .init(re: a.re + b.re, im: a.im + b.im)
        }
        static func - (a: Complex, b: Complex) -> Complex {
            .init(re: a.re - b.re, im: a.im - b.im)
        }
        static func * (a: Complex, b: Double) -> Complex {
            .init(re: a.re * b, im: a.im * b)
        }
        var magnitude: Double { hypot(re, im) }
    }

    private static func responseBasis(frequency: Double, sampleRate: Double)
        -> [Complex] {
        let radians = 2 * Double.pi * frequency / sampleRate
        let c = cos(radians), s = sin(radians)
        let lowpasses: [Complex] = crossoverHz.map { cutoff in
            let alpha = 1 - exp(-2 * Double.pi * cutoff / sampleRate)
            let a = 1 - (1 - alpha) * c
            let b = (1 - alpha) * s
            let divisor = max(1.0e-20, a * a + b * b)
            return Complex(re: alpha * a / divisor,
                           im: -alpha * b / divisor)
        }
        var basis: [Complex] = [lowpasses[0]]
        for i in 1..<5 { basis.append(lowpasses[i] - lowpasses[i - 1]) }
        basis.append(Complex(re: 1, im: 0) - lowpasses[4])
        return basis
    }

    static func responseMagnitudes(gains: [Float], sampleRate: Double) -> [Double] {
        guard gains.count == 6, sampleRate.isFinite, sampleRate > 8_000 else { return [] }
        return centersHz.map { center in
            let basis = responseBasis(frequency: center, sampleRate: sampleRate)
            var response = Complex(re: 0, im: 0)
            for band in 0..<6 { response = response + basis[band] * Double(gains[band]) }
            return response.magnitude
        }
    }

    /// Six precomputed gains for one feedback delay line. If invalid inputs
    /// are supplied return original coefficients. The optimization is
    /// deterministic, bounded, and never called by process().
    static func gains(targetRT60: [Float], delayFrames: Int, sampleRate: Double)
        -> [Float] {
        guard targetRT60.count == 6, delayFrames > 1,
              sampleRate.isFinite, sampleRate >= 8_000,
              targetRT60.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return targetRT60.map { _ in 0.5 }
        }
        let seconds = Double(delayFrames) / sampleRate
        let desired: [Double] = targetRT60.map {
            pow(10, -3 * seconds / Double(max(0.2, min(15, $0))))
        }
        let basis = centersHz.map { responseBasis(frequency: $0, sampleRate: sampleRate) }
        var fitted = desired.map { min(0.995, max(0.001, $0)) }

        func objective(_ gains: [Double]) -> Double {
            var score = 0.0
            for frequency in 0..<6 {
                var sum = Complex(re: 0, im: 0)
                for index in 0..<6 {
                    sum = sum + basis[frequency][index] * gains[index]
                }
                let delta = sum.magnitude - desired[frequency]
                score += delta * delta
            }
            // Preserve musical character rather than aggressively inverting
            // crossovers near the edge of feedback stability.
            for index in 0..<6 {
                let delta = gains[index] - desired[index]
                score += 0.03 * delta * delta
            }
            return score
        }

        // Coordinate descent. Only 6 x 6 complex basis values, prepared once
        // per delay line OFF the audio thread (16 lines per custom room).
        for step in [0.08, 0.04, 0.02, 0.01, 0.005, 0.002] {
            for _ in 0..<3 {
                for index in 0..<6 {
                    var best = objective(fitted)
                    for direction in [-1.0, 1.0] {
                        var candidate = fitted
                        candidate[index] = min(0.995, max(0.001,
                                                         fitted[index] + direction * step))
                        let score = objective(candidate)
                        if score < best {
                            fitted = candidate
                            best = score
                        }
                    }
                }
            }
        }
        return fitted.map(Float.init)
    }
}
