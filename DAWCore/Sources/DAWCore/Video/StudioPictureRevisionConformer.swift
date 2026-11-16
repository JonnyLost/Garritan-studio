import Foundation

/// The same recognizable story moment in both edits, measured in picture frames.
/// Ordered anchors support inserted/removed footage without moving unrelated cues
/// by a single global offset.
public struct StudioPictureRevisionAnchor: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var oldFrame: Int64
    public var newFrame: Int64

    public init(id: UUID = UUID(), oldFrame: Int64, newFrame: Int64) {
        self.id = id
        self.oldFrame = oldFrame
        self.newFrame = newFrame
    }
}

public struct StudioPictureRevisionCueChange: Identifiable, Equatable, Sendable {
    public var id: UUID { cueID }
    public let cueID: UUID
    public let name: String
    public let previousFrame: Int64
    /// Nil means the planned edit would place this cue outside the new movie.
    public let proposedFrame: Int64?
    public let previousTimecode: String
    public let proposedTimecode: String?
}

public struct StudioPictureRevisionPreview: Sendable {
    public let changes: [StudioPictureRevisionCueChange]
    public let anchors: [StudioPictureRevisionAnchor]

    public var unresolvedCount: Int {
        changes.filter { $0.proposedFrame == nil }.count
    }
    public var movedCount: Int {
        changes.filter { $0.proposedFrame != nil &&
            $0.proposedFrame != $0.previousFrame }.count
    }
}

public enum StudioPictureRevisionConformer {
    public enum ConformError: Error, LocalizedError {
        case invalidAnchors
        case incompatibleMedia
        case unresolvedCues
        case pictureChanged

        public var errorDescription: String? {
            switch self {
            case .invalidAnchors:
                return "Match points must be inside each movie and increase strictly in both edits."
            case .incompatibleMedia:
                return "The reference movie has invalid duration or frame rate."
            case .unresolvedCues:
                return "Some cues fall outside the replacement film. Add or adjust match points before applying."
            case .pictureChanged:
                return "The source picture changed during conform. Review the revision again."
            }
        }
    }

    /// Build a non-destructive preview. Match points are piecewise *offsets*
    /// anchored in absolute elapsed time, never a time stretch of the music.
    /// The nearest preceding anchor controls each interval. Before the first
    /// match, the first anchor is used. This supports discrete insertions and
    /// cuts while keeping the original hit IDs and note text.
    public static func preview(old: StudioPictureProject,
                               replacement: StudioPictureProject,
                               anchors: [StudioPictureRevisionAnchor]) throws
        -> StudioPictureRevisionPreview {
        guard old.totalFrames > 0, replacement.totalFrames > 0,
              old.frameRate.framesPerSecond > 0,
              replacement.frameRate.framesPerSecond > 0 else {
            throw ConformError.incompatibleMedia
        }
        let ordered = anchors.sorted { $0.oldFrame < $1.oldFrame }
        guard !ordered.isEmpty,
              ordered.allSatisfy({
                  $0.oldFrame >= 0 && $0.oldFrame < old.totalFrames &&
                  $0.newFrame >= 0 && $0.newFrame < replacement.totalFrames
              }),
              zip(ordered, ordered.dropFirst()).allSatisfy({
                  $0.oldFrame < $1.oldFrame && $0.newFrame < $1.newFrame
              }) else { throw ConformError.invalidAnchors }

        let oldFPS = old.frameRate.framesPerSecond
        let newFPS = replacement.frameRate.framesPerSecond
        let cues = old.hitPoints.map { hit -> StudioPictureRevisionCueChange in
            let anchor = ordered.last(where: { $0.oldFrame <= hit.frame }) ?? ordered[0]
            let converted = Double(anchor.newFrame) +
                Double(hit.frame - anchor.oldFrame) * newFPS / oldFPS
            let target: Int64?
            if converted.isFinite, converted >= 0,
               converted < Double(replacement.totalFrames),
               converted <= Double(Int64.max) {
                target = Int64(converted.rounded())
            } else {
                target = nil
            }
            let safeTarget = target.flatMap {
                $0 >= 0 && $0 < replacement.totalFrames ? $0 : nil
            }
            return StudioPictureRevisionCueChange(
                cueID: hit.id, name: hit.name, previousFrame: hit.frame,
                proposedFrame: safeTarget,
                previousTimecode: old.timecode(atMovieFrame: hit.frame),
                proposedTimecode: safeTarget.map {
                    replacement.timecode(atMovieFrame: $0)
                })
        }
        return StudioPictureRevisionPreview(changes: cues, anchors: ordered)
    }

    /// Apply only a fully resolved and previously inspected preview. Preserve
    /// cue IDs/notes/types, start TC convention and picture offset. Never move
    /// or rewrite musical clips, tempo, instruments or timeline regions.
    public static func conform(old: StudioPictureProject,
                               replacement: StudioPictureProject,
                               preview: StudioPictureRevisionPreview) throws
        -> StudioPictureProject {
        guard preview.unresolvedCount == 0,
              preview.changes.count == old.hitPoints.count,
              Set(preview.changes.map(\.cueID)) == Set(old.hitPoints.map(\.id)),
              preview.changes.allSatisfy({ change in
                  old.hitPoints.contains(where: {
                      $0.id == change.cueID && $0.frame == change.previousFrame
                  })
              }) else { throw ConformError.unresolvedCues }
        let fresh = try self.preview(old: old, replacement: replacement,
                                     anchors: preview.anchors)
        guard zip(fresh.changes, preview.changes).allSatisfy({
            $0.cueID == $1.cueID && $0.proposedFrame == $1.proposedFrame
        }) else { throw ConformError.pictureChanged }

        var result = replacement
        result.timelineStartSeconds = old.timelineStartSeconds
        result.referenceAudioEnabled = old.referenceAudioEnabled
        result.referenceAudioVolume = old.referenceAudioVolume
        result.showTimecodeOverlay = old.showTimecodeOverlay
        result.showScoringStreamers = old.showScoringStreamers
        result.showScoringPunches = old.showScoringPunches
        result.streamerLeadSeconds = old.streamerLeadSeconds
        // Carry the starting *label* across changes in frame-rate numbering.
        // Invalid DF labels are never silently synthesized.
        let startingLabel = old.timecode(atMovieFrame: 0)
        result.startTimecodeFrame = StudioPictureTimecode.frameNumber(
            startingLabel, rate: replacement.frameRate) ??
            (StudioPictureTimecode.frameNumber(
                "01:00:00:00", rate: replacement.frameRate) ?? 0)
        let mapping = Dictionary(uniqueKeysWithValues: fresh.changes.compactMap {
            change -> (UUID, Int64)? in
            guard let frame = change.proposedFrame else { return nil }
            return (change.cueID, frame)
        })
        result.hitPoints = old.hitPoints.map { hit in
            var updated = hit
            if let mapped = mapping[hit.id] { updated.frame = mapped }
            return updated
        }
        return result
    }
}
