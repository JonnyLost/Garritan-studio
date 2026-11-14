import Foundation

/// Original Studio-owned, side-effect-free musical clock conversions.
///
/// Both output backends must agree about beat/sample positions. Calculations
/// preserve truncation-toward-zero used in the existing playback engine, while
/// rejecting non-finite tempo, sample rates, or beat positions before converting
/// to Int64 (which would otherwise trap or overflow).
public enum StudioMIDIClockMath {
    /// Clamp to Int64 range to avoid runtime traps on malformed/imported data.
    public static func samples(
        forBeats beats: Double,
        tempoBPM: Double,
        sampleRate: Double
    ) -> Int64 {
        guard beats.isFinite, tempoBPM.isFinite, tempoBPM > 0,
              sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let result = beats * (60.0 / tempoBPM) * sampleRate
        guard result.isFinite else { return result.sign == .minus ? Int64.min : Int64.max }
        // Double(Int64.max) rounds to 2^63; do not pass that to Int64.init.
        if result >= 9_223_372_036_854_775_808.0 { return Int64.max }
        if result <= -9_223_372_036_854_775_808.0 { return Int64.min }
        return Int64(result)
    }

    public static func beats(
        forSamples samples: Int64,
        tempoBPM: Double,
        sampleRate: Double
    ) -> Double {
        guard tempoBPM.isFinite, tempoBPM > 0,
              sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let result = Double(samples) * (tempoBPM / (60.0 * sampleRate))
        return result.isFinite ? result : 0
    }

    /// The end sample of a render buffer is exclusive. Saturate in the
    /// extremely unlikely event that the transport reaches Int64.max.
    public static func bufferEnd(startSample: Int64, frameCount: UInt32) -> Int64 {
        let frames = Int64(frameCount)
        if startSample > Int64.max - frames { return Int64.max }
        return startSample + frames
    }
}
