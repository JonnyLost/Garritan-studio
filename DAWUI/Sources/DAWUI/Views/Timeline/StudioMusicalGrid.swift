import Foundation
import DAWCore

/// Quarter-note beats are the shared timeline unit. A bar in 6/8 is three
/// quarter-note beats, not six; keep snap and ruler math in one place.
enum StudioMusicalGrid {
    static func beatsPerBar(_ signature: TimeSignature) -> Double {
        let numerator = max(1, signature.numerator)
        let denominator = max(1, signature.denominator)
        return Double(numerator) * 4.0 / Double(denominator)
    }

    /// Interior quarter-note markers relative to the START of each bar.
    /// In 7/8 the bar is 3.5 quarters: marks 1, 2 and 3, and the
    /// next bar begins at 3.5. Global integer beat lines are incorrect.
    static func interiorQuarterBeats(_ signature: TimeSignature) -> [Double] {
        let length = beatsPerBar(signature)
        guard length.isFinite, length > 1, length < 1024 else { return [] }
        return (1...Int(ceil(length))).compactMap { index in
            let beat = Double(index)
            return beat < length ? beat : nil
        }
    }

    static func snap(_ beat: Double, division: Double, bypass: Bool = false) -> Double {
        guard beat.isFinite else { return 0 }
        let clampedBeat = max(0, beat)
        guard !bypass, division.isFinite, division > 0 else { return clampedBeat }
        return max(0, (clampedBeat / division).rounded() * division)
    }

    static func snap(_ beat: Double, mode: SnapMode,
                     timeSignature: TimeSignature, bypass: Bool = false) -> Double {
        let division = mode == .bar ? beatsPerBar(timeSignature) : mode.division
        return snap(beat, division: division, bypass: bypass)
    }
}
