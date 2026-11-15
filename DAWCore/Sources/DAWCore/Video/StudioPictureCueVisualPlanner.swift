import Foundation

/// Deterministic film-scoring visual cues. This is pure frame math: the UI
/// samples the current transport position and never schedules work on the
/// real-time audio thread.
public struct StudioPictureCueVisual: Equatable, Sendable {
    public let hitID: UUID
    public let name: String
    /// 0 when the streamer begins at the left edge, 1 at the punch frame.
    public let progress: Double
    public let isPunch: Bool

    public init(hitID: UUID, name: String, progress: Double, isPunch: Bool) {
        self.hitID = hitID
        self.name = name
        self.progress = progress
        self.isPunch = isPunch
    }
}

public enum StudioPictureCueVisualPlanner {
    /// Returns a single upcoming or currently flashing cue. Past hits never
    /// mask a nearer upcoming cue. Frame duration, not wall-clock time, defines
    /// the single-frame punch and pre-roll countdown.
    public static func visual(picture: StudioPictureProject,
                              projectSeconds: Double) -> StudioPictureCueVisual? {
        guard projectSeconds.isFinite,
              picture.durationSeconds > 0,
              picture.frameRate.framesPerSecond.isFinite,
              picture.frameRate.framesPerSecond > 0,
              (picture.showScoringStreamers ?? true) ||
                (picture.showScoringPunches ?? true) else { return nil }

        let rate = picture.frameRate.framesPerSecond
        let framePosition = (projectSeconds - picture.timelineStartSeconds) * rate
        guard framePosition.isFinite, framePosition >= 0,
              framePosition < Double(picture.totalFrames) else { return nil }

        let requestedLead = picture.streamerLeadSeconds ?? 3
        let leadSeconds = requestedLead.isFinite ? min(10, max(0.5, requestedLead)) : 3
        let leadFrames = max(1, Int64((leadSeconds * rate).rounded()))
        let currentFrame = Int64(framePosition.rounded(.down))
        let upcoming = picture.hitPoints
            .filter { $0.frame >= currentFrame && $0.frame < picture.totalFrames }
            .min { lhs, rhs in
                if lhs.frame == rhs.frame { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.frame < rhs.frame
            }
        guard let hit = upcoming else { return nil }
        let framesUntilHit = hit.frame - currentFrame
        guard framesUntilHit >= 0 && framesUntilHit <= leadFrames else { return nil }
        let isPunch = framesUntilHit == 0 && (picture.showScoringPunches ?? true)
        let showStreamer = picture.showScoringStreamers ?? true
        guard isPunch || (showStreamer && framesUntilHit > 0) else { return nil }
        let progress = min(1, max(0, 1 - Double(framesUntilHit) / Double(leadFrames)))
        return StudioPictureCueVisual(hitID: hit.id, name: hit.name,
                                      progress: progress, isPunch: isPunch)
    }
}
