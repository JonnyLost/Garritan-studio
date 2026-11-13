import Foundation

/// Offline impulse-response measurements for Studio reverb development.
/// This is NOT audio-thread code and is NOT an ISO 3382 conformant
/// analyzer: bandpass filters are 2nd-order octave approximations and finite
/// impulse-response tails are not noise-floor-corrected. Never describe
/// these numbers as measured characteristics of a named real venue.
public struct NativeRoomDecayMetrics: Codable, Sendable {
    public let bandCenterHz: Double
    public let edtSeconds: Double?
    public let t20Seconds: Double?
    public let t30Seconds: Double?
}

public struct NativeRoomCalibrationResult: Codable, Sendable {
    public let roomID: String
    public let sampleRate: Double
    public let durationSeconds: Double
    public let bands: [NativeRoomDecayMetrics]
    /// Wet-only early / late energy split. Not C80 for a complete direct+wet mix.
    public let wetOnlyC80dB: Double?
}

public enum NativeRoomImpulseAnalyzer {
    /// Deterministic wet-only impulse render. Instantiate/process offline,
    /// never on the real-time audio thread. The same FDN as the AU is used.
    public static func render(room: StudioRoomAcousticProfile,
                              sampleRate: Double = 48_000,
                              seconds: Double = 5) -> ([Float], [Float]) {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              seconds.isFinite, (0.1...20).contains(seconds) else { return ([], []) }
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0, count: frames)
        var right = left
        left[0] = 1
        right[0] = 1
        // Mirror the actual native hall: one position-aware track ER path
        // summed with the shared FDN (which must NOT duplicate those taps).
        var earlyLeft = left
        var earlyRight = right
        let late = NativeRoomReverbProcessor(sampleRate: sampleRate,
                                             profiles: [room],
                                             includeEarlyReflections: false)
        let early = NativeStageEarlyReflectionProcessor(sampleRate: sampleRate,
                                                        profiles: [room])
        early.update(roomIndex: 0, pan: 0, zone: 2)
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                guard let l = lb.baseAddress, let r = rb.baseAddress else { return }
                let chunk = 512
                var offset = 0
                while offset < frames {
                    let count = min(chunk, frames - offset)
                    late.process(left: l.advanced(by: offset),
                                 right: r.advanced(by: offset), frameCount: count)
                    offset += count
                }
            }
        }
        earlyLeft.withUnsafeMutableBufferPointer { lb in
            earlyRight.withUnsafeMutableBufferPointer { rb in
                guard let l = lb.baseAddress, let r = rb.baseAddress else { return }
                let chunk = 512
                var offset = 0
                while offset < frames {
                    let count = min(chunk, frames - offset)
                    early.process(left: l.advanced(by: offset),
                                  right: r.advanced(by: offset), frameCount: count)
                    offset += count
                }
            }
        }
        for index in left.indices {
            left[index] += earlyLeft[index]
            right[index] += earlyRight[index]
        }
        return (left, right)
    }

    /// Reports approximate EDT/T20/T30 using backwards energy integration
    /// and least-squares slopes, with stereo-energy C80 on the wet-only impulse response.
    /// Nil means there was insufficient dynamic range to make that estimate.
    public static func analyze(left: [Float], right: [Float],
                               sampleRate: Double, roomID: String) -> NativeRoomCalibrationResult {
        guard sampleRate.isFinite && sampleRate > 0,
              left.count == right.count, !left.isEmpty else {
            return NativeRoomCalibrationResult(roomID: roomID, sampleRate: sampleRate,
                                               durationSeconds: 0, bands: [], wetOnlyC80dB: nil)
        }
        // Keep stereo energy separate. Averaging L and R can cancel the
        // decorrelated, opposite-polarity FDN outputs and distort decay fits.
        let stereoLeft = left.map(Double.init)
        let stereoRight = right.map(Double.init)
        let bands = StudioAcousticRoomDesign.bandCentersHz.map { frequency -> NativeRoomDecayMetrics in
            let center = Double(frequency)
            guard center < sampleRate * 0.45 else {
                // The analysis filter cannot resolve frequencies near/above
                // Nyquist. Returning nil is preferable to fabricating a value.
                return NativeRoomDecayMetrics(bandCenterHz: center,
                                              edtSeconds: nil, t20Seconds: nil,
                                              t30Seconds: nil)
            }
            let filteredL = octaveApproximate(stereoLeft, sampleRate: sampleRate,
                                               centerHz: center)
            let filteredR = octaveApproximate(stereoRight, sampleRate: sampleRate,
                                               centerHz: center)
            let decay = backwardIntegratedDecibels(left: filteredL, right: filteredR)
            return NativeRoomDecayMetrics(
                bandCenterHz: center,
                edtSeconds: fit(decay, fromDB: 0, throughDB: -10, sampleRate: sampleRate),
                t20Seconds: fit(decay, fromDB: -5, throughDB: -25, sampleRate: sampleRate),
                t30Seconds: fit(decay, fromDB: -5, throughDB: -35, sampleRate: sampleRate)
            )
        }
        let cutoff = min(left.count, Int((0.080 * sampleRate).rounded()))
        var early = 0.0
        var late = 0.0
        for index in left.indices {
            let total = stereoLeft[index] * stereoLeft[index] +
                        stereoRight[index] * stereoRight[index]
            if index < cutoff { early += total } else { late += total }
        }
        let c80: Double? = early > 0 && late > 0 ? 10 * log10(early / late) : nil
        return NativeRoomCalibrationResult(
            roomID: roomID, sampleRate: sampleRate,
            durationSeconds: Double(mono.count) / sampleRate,
            bands: bands, wetOnlyC80dB: c80
        )
    }

    public static func measure(room: StudioRoomAcousticProfile,
                               sampleRate: Double = 48_000, seconds: Double = 5)
        -> NativeRoomCalibrationResult {
        let (l, r) = render(room: room, sampleRate: sampleRate, seconds: seconds)
        return analyze(left: l, right: r, sampleRate: sampleRate, roomID: room.id)
    }

    /// Simple bandpass, center frequency and approximately one-octave Q.
    /// Not an IEC 61260 measurement filter; intended for repeatable tuning.
    private static func octaveApproximate(_ signal: [Double], sampleRate: Double,
                                           centerHz: Double) -> [Double] {
        guard centerHz < sampleRate * 0.45 else { return signal }
        let omega = 2 * Double.pi * centerHz / sampleRate
        let alpha = sin(omega) / (2 * 1.41421356237)
        let a0 = 1 + alpha
        let b0 = alpha / a0
        let b2 = -alpha / a0
        let a1 = -2 * cos(omega) / a0
        let a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var output = [Double]()
        output.reserveCapacity(signal.count)
        for x in signal {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            output.append(y)
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
        }
        return output
    }

    private static func backwardIntegratedDecibels(left: [Double],
                                                     right: [Double]) -> [Double] {
        var energies = [Double](repeating: 0, count: left.count)
        var sum = 0.0
        for index in left.indices.reversed() {
            let l = left[index], r = right[index]
            sum += l * l + r * r
            energies[index] = sum
        }
        guard sum.isFinite && sum > 1.0e-25 else { return [] }
        return energies.map { $0 > 0 ? 10 * log10($0 / sum) : -.infinity }
    }

    /// Line fit using all samples within the indicated dB range.
    /// Output extrapolates to a 60dB energy decay, matching T20/T30 convention.
    private static func fit(_ decay: [Double], fromDB upper: Double,
                            throughDB lower: Double, sampleRate: Double) -> Double? {
        guard !decay.isEmpty else { return nil }
        var count = 0.0, sumX = 0.0, sumY = 0.0
        var sumXX = 0.0, sumXY = 0.0
        var didReachLower = false
        for (index, db) in decay.enumerated() {
            if db <= lower { didReachLower = true }
            guard db.isFinite, db <= upper, db >= lower else { continue }
            let t = Double(index) / sampleRate
            count += 1
            sumX += t
            sumY += db
            sumXX += t * t
            sumXY += t * db
        }
        guard didReachLower, count > 10 else { return nil }
        let denominator = count * sumXX - sumX * sumX
        guard denominator > 0 else { return nil }
        let slope = (count * sumXY - sumX * sumY) / denominator
        guard slope.isFinite && slope < -0.01 else { return nil }
        let value = -60 / slope
        return value.isFinite && value > 0 && value < 60 ? value : nil
    }
}
