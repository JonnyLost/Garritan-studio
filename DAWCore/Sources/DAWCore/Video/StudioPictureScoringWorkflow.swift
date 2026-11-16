import Foundation

/// A small, deterministic synchronization policy. The real-time audio thread
/// is never involved; AVPlayer is only corrected for large discontinuities or
/// meaningful drift, rather than seeking on every transport callback.
public struct StudioPictureSyncDecision: Equatable, Sendable {
    public let targetSeconds: Double
    public let shouldSeek: Bool
    public let shouldPlay: Bool
    public let outsideMovieRange: Bool

    public init(targetSeconds: Double, shouldSeek: Bool,
                shouldPlay: Bool, outsideMovieRange: Bool) {
        self.targetSeconds = targetSeconds
        self.shouldSeek = shouldSeek
        self.shouldPlay = shouldPlay
        self.outsideMovieRange = outsideMovieRange
    }
}

public enum StudioPictureSyncPlanner {
    /// Returns an AVPlayer action from a sample-clock timestamp. Transport
    /// time is always expressed in seconds and never in beat display units.
    ///
    /// - Parameters:
    ///   - movieSeconds: current actual AVPlayer time, or nil if unavailable
    ///   - secondsSinceCorrection: elapsed monotonic time since the last video seek
    ///   - discontinuity: loop wrap, an explicit seek, or return-to-zero
    public static func plan(picture: StudioPictureProject,
                            projectSeconds: Double,
                            movieSeconds: Double?,
                            isPlaying: Bool,
                            secondsSinceCorrection: Double,
                            discontinuity: Bool = false) -> StudioPictureSyncDecision {
        guard projectSeconds.isFinite, picture.durationSeconds.isFinite,
              picture.durationSeconds > 0 else {
            return StudioPictureSyncDecision(
                targetSeconds: 0, shouldSeek: false,
                shouldPlay: false, outsideMovieRange: true)
        }

        let relative = projectSeconds - picture.timelineStartSeconds
        let inside = relative >= 0 && relative < picture.durationSeconds
        let frameDuration = 1.0 / picture.frameRate.framesPerSecond
        let latest = max(0, picture.durationSeconds - frameDuration)
        let target = min(latest, max(0, relative))
        let actual = movieSeconds.flatMap { $0.isFinite ? $0 : nil }
        let error = actual.map { abs($0 - target) } ?? .infinity
        // A two-frame sync budget respects 23.976 through 60 fps instead of
        // accepting the same 100 ms error for every format. Seek correction
        // stays throttled to keep long film sessions MacBook-friendly.
        let threshold = isPlaying ? max(0.05, frameDuration * 2) : frameDuration * 0.5
        let allowed = discontinuity || !isPlaying ||
            secondsSinceCorrection >= 0.65

        return StudioPictureSyncDecision(
            targetSeconds: target,
            shouldSeek: allowed && (discontinuity || error > threshold),
            shouldPlay: isPlaying && inside,
            outsideMovieRange: !inside)
    }

    /// Detect explicit locator jumps and loop wraps without conflating them
    /// with harmless audio callback jitter.
    public static func isDiscontinuity(
        previousProjectSeconds: Double?,
        previousUptime: Double?,
        currentProjectSeconds: Double,
        uptime: Double
    ) -> Bool {
        guard let previousProjectSeconds, let previousUptime,
              previousProjectSeconds.isFinite, previousUptime.isFinite,
              currentProjectSeconds.isFinite, uptime.isFinite else { return true }
        let elapsed = max(0, uptime - previousUptime)
        let advance = currentProjectSeconds - previousProjectSeconds
        return advance < -0.030 || advance > elapsed + 0.35
    }
}

/// Portable cue sheet export for directors, editors and scoring sessions.
/// CSV contains only frame-based cue data and is safe to open in spreadsheets.
public enum StudioPictureCueSheet {
    public static func csv(for picture: StudioPictureProject) -> String {
        let header = ["Cue", "Type", "SMPTE", "Picture Frame",
                      "Project Seconds", "Notes"].joined(separator: ",")
        let rows = picture.hitPoints
            .sorted { lhs, rhs in
                if lhs.frame == rhs.frame { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.frame < rhs.frame
            }
            .map { hit in
                [
                    escaped(hit.name),
                    escaped(hit.kind.label),
                    escaped(picture.timecode(atMovieFrame: hit.frame)),
                    String(hit.frame),
                    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                           picture.projectSeconds(atMovieFrame: hit.frame)),
                    escaped(hit.notes)
                ].joined(separator: ",")
            }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private static func escaped(_ text: String) -> String {
        // Prevent spreadsheet CSV-formula execution when a cue is opened in
        // Excel or Numbers. Preserve ordinary punctuation and multiline notes.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.first.map { "=+-@".contains($0) } ?? false
        let sanitized = prefix ? "'" + text : text
        return "\"" + sanitized.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
