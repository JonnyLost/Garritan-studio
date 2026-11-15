import Foundation

/// Non-mutating film cue navigation. All search and locator operations use
/// frame-based picture coordinates; they never rewrite MIDI or project tempo.
public enum StudioPictureCueNavigation {
    public static func matching(_ picture: StudioPictureProject,
                                query: String,
                                kind: StudioPictureHitKind? = nil)
        -> [StudioPictureHitPoint] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return picture.hitPoints
            .filter { hit in
                let kindMatches = kind == nil || hit.kind == kind
                let textMatches = normalized.isEmpty ||
                    hit.name.localizedStandardContains(normalized) ||
                    hit.notes.localizedStandardContains(normalized) ||
                    picture.timecode(atMovieFrame: hit.frame)
                        .localizedStandardContains(normalized)
                return kindMatches && textMatches
            }
            .sorted {
                $0.frame == $1.frame
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.frame < $1.frame
            }
    }

    public static func adjacent(_ picture: StudioPictureProject,
                                currentFrame: Int64, direction: Int,
                                query: String = "",
                                kind: StudioPictureHitKind? = nil)
        -> StudioPictureHitPoint? {
        let hits = matching(picture, query: query, kind: kind)
        return direction < 0
            ? hits.last(where: { $0.frame < currentFrame })
            : hits.first(where: { $0.frame > currentFrame })
    }

    /// A production-facing locator: absolute SMPTE labels translate to
    /// movie-relative frames (with midnight rollover) before seeking.
    public static func frame(forEnteredTimecode text: String,
                             picture: StudioPictureProject) -> Int64? {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count == 11 else { return nil }
        return picture.movieFrame(forTimecode: label)
    }
}
