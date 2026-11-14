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
