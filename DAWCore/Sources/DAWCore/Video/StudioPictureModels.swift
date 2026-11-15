import Foundation

/// SMPTE frame-rate and numbering policy. 29.97/59.94 drop-frame modes skip
/// timecode *labels*, never picture frames.
public enum StudioPictureFrameRate: String, Codable, CaseIterable, Sendable, Identifiable {
    case fps23976, fps24, fps25, fps2997, fps2997Drop, fps30
    case fps50, fps5994, fps5994Drop, fps60

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fps23976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps2997: return "29.97 NDF"
        case .fps2997Drop: return "29.97 DF"
        case .fps30: return "30"
        case .fps50: return "50"
        case .fps5994: return "59.94 NDF"
        case .fps5994Drop: return "59.94 DF"
        case .fps60: return "60"
        }
    }

    public var framesPerSecond: Double {
        switch self {
        case .fps23976: return 24_000.0 / 1_001.0
        case .fps2997, .fps2997Drop: return 30_000.0 / 1_001.0
        case .fps5994, .fps5994Drop: return 60_000.0 / 1_001.0
        case .fps24: return 24
        case .fps25: return 25
        case .fps30: return 30
        case .fps50: return 50
        case .fps60: return 60
        }
    }

    public var nominalFPS: Int64 {
        switch self {
        case .fps23976, .fps24: return 24
        case .fps25: return 25
        case .fps2997, .fps2997Drop, .fps30: return 30
        case .fps50: return 50
        case .fps5994, .fps5994Drop, .fps60: return 60
        }
    }

    public var droppedLabelsPerMinute: Int64 {
        switch self {
        case .fps2997Drop: return 2
        case .fps5994Drop: return 4
        default: return 0
        }
    }

    public static func closest(to fps: Double) -> StudioPictureFrameRate {
        guard fps.isFinite, fps > 0 else { return .fps24 }
        // Do not infer a drop-frame *numbering* mode from a movie's frame rate.
        return [.fps23976, .fps24, .fps25, .fps2997, .fps30,
                .fps50, .fps5994, .fps60]
            .min(by: { abs($0.framesPerSecond - fps) < abs($1.framesPerSecond - fps) }) ?? .fps24
    }
}

/// Stable integer-frame conversion. Keep SMPTE label math separate from real
/// elapsed seconds: drop-frame is not a video speed adjustment.
public enum StudioPictureTimecode {
    public static func frameNumber(_ text: String, rate: StudioPictureFrameRate) -> Int64? {
        let components = text.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard components.count == 4,
              let hours = Int64(components[0]), (0..<24).contains(hours),
              let minutes = Int64(components[1]), (0..<60).contains(minutes),
              let seconds = Int64(components[2]), (0..<60).contains(seconds),
              let frames = Int64(components[3]), (0..<rate.nominalFPS).contains(frames)
        else { return nil }
        let drop = rate.droppedLabelsPerMinute
        // The first two (or four) frame labels of a non-tenth minute do not exist.
        if drop > 0 && minutes % 10 != 0 && seconds == 0 && frames < drop {
            return nil
        }
        let totalMinutes = hours * 60 + minutes
        let nominal = ((hours * 3600 + minutes * 60 + seconds) * rate.nominalFPS) + frames
        return nominal - drop * (totalMinutes - totalMinutes / 10)
    }

    public static func string(frameNumber: Int64, rate: StudioPictureFrameRate) -> String {
        let fps = rate.nominalFPS
        let drop = rate.droppedLabelsPerMinute
        let perDay = fps * 86_400 - drop * (1_440 - 144)
        let wrapped = ((frameNumber % perDay) + perDay) % perDay

        var labelled = wrapped
        if drop > 0 {
            let framesPerTenMinutes = fps * 600 - drop * 9
            let framesPerDropMinute = fps * 60 - drop
            let completeTenMinuteBlocks = wrapped / framesPerTenMinutes
            let remainder = wrapped % framesPerTenMinutes
            labelled += completeTenMinuteBlocks * drop * 9
            if remainder >= drop {
                labelled += drop * ((remainder - drop) / framesPerDropMinute)
            }
        }
        let frames = labelled % fps
        let seconds = (labelled / fps) % 60
        let minutes = (labelled / (fps * 60)) % 60
        let hours = (labelled / (fps * 3600)) % 24
        let separator = drop == 0 ? ":" : ";"
        return String(format: "%02lld:%02lld:%02lld%@%02lld",
                      hours, minutes, seconds, separator, frames)
    }
}

public enum StudioPictureHitKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case cut, impact, action, dialogue, custom
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public struct StudioPictureHitPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Frame offset from the beginning of the imported movie, not an audio beat.
    public var frame: Int64
    public var kind: StudioPictureHitKind
    public var notes: String

    public init(id: UUID = UUID(), name: String, frame: Int64,
                kind: StudioPictureHitKind = .impact, notes: String = "") {
        self.id = id
        self.name = name
        self.frame = max(0, frame)
        self.kind = kind
        self.notes = notes
    }
}

/// A project stores one reference picture plus frame-based cue annotations.
/// The media remains external; it is not duplicated into the saved DAW document.
public struct StudioPictureProject: Codable, Equatable, Sendable {
    public var filename: String
    public var filePath: String
    /// Unique import/relink token; replaces a movie even when the path did not change.
    /// Optional for compatibility with earlier Studio Picture documents.
    public var mediaRevisionID: UUID?
    public var securityBookmark: Data?
    public var durationSeconds: Double
    public var frameRate: StudioPictureFrameRate
    /// Project's sample-time position at which the first movie frame appears.
    public var timelineStartSeconds: Double
    /// SMPTE label assigned to the first movie frame (e.g. 01:00:00:00).
    public var startTimecodeFrame: Int64
    public var referenceAudioEnabled: Bool
    /// Linear monitor gain, not part of the score or stem mix. Nil means 65%.
    public var referenceAudioVolume: Float?
    /// Optional so first-generation Studio Picture projects remain readable.
    /// Nil means the normal visible overlay default.
    public var showTimecodeOverlay: Bool?
    public var hitPoints: [StudioPictureHitPoint]

    public init(url: URL, durationSeconds: Double, frameRate: StudioPictureFrameRate,
                securityBookmark: Data? = nil, mediaRevisionID: UUID? = UUID(),
                timelineStartSeconds: Double = 0,
                startTimecodeFrame: Int64? = nil, referenceAudioEnabled: Bool = false,
                referenceAudioVolume: Float? = nil,
                showTimecodeOverlay: Bool = true,
                hitPoints: [StudioPictureHitPoint] = []) {
        self.filename = url.lastPathComponent
        self.filePath = url.path
        self.mediaRevisionID = mediaRevisionID
        self.securityBookmark = securityBookmark
        self.durationSeconds = max(0, durationSeconds.isFinite ? durationSeconds : 0)
        self.frameRate = frameRate
        self.timelineStartSeconds = max(0, timelineStartSeconds.isFinite ? timelineStartSeconds : 0)
        self.startTimecodeFrame = startTimecodeFrame ??
            (StudioPictureTimecode.frameNumber("01:00:00:00", rate: frameRate) ?? 0)
        self.referenceAudioEnabled = referenceAudioEnabled
        self.referenceAudioVolume = referenceAudioVolume
        self.showTimecodeOverlay = showTimecodeOverlay
        self.hitPoints = hitPoints
    }

    public var totalFrames: Int64 {
        Int64(max(0, (durationSeconds * frameRate.framesPerSecond).rounded(.down)))
    }

    public func movieFrame(atProjectSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let frame = Int64(max(0, (seconds - timelineStartSeconds) * frameRate.framesPerSecond).rounded(.down))
        return min(frame, max(0, totalFrames - 1))
    }

    public func projectSeconds(atMovieFrame frame: Int64) -> Double {
        timelineStartSeconds + Double(max(0, frame)) / frameRate.framesPerSecond
    }

    /// Converts a user-entered SMPTE label back to a picture-relative frame.
    /// Handles the 24-hour label wrap used by standard SMPTE clocks.
    public func movieFrame(forTimecode label: String) -> Int64? {
        guard let absolute = StudioPictureTimecode.frameNumber(label, rate: frameRate),
              totalFrames > 0 else { return nil }
        let drop = frameRate.droppedLabelsPerMinute
        let framesInDay = frameRate.nominalFPS * 86_400 - drop * (1_440 - 144)
        var relative = absolute - startTimecodeFrame
        if relative < 0 { relative += framesInDay }
        guard relative >= 0, relative < totalFrames else { return nil }
        return relative
    }

    public func timecode(atMovieFrame frame: Int64) -> String {
        StudioPictureTimecode.string(frameNumber: startTimecodeFrame + frame, rate: frameRate)
    }

    /// Suggested BPM for a chosen number of beats between two hit points.
    /// Advisory only: it never changes the arrangement's tempo automatically.
    public func suggestedTempo(from first: StudioPictureHitPoint,
                               to second: StudioPictureHitPoint,
                               beats: Double = 8) -> Double? {
        let interval = Double(second.frame - first.frame) / frameRate.framesPerSecond
        guard interval > 0, beats.isFinite, beats > 0 else { return nil }
        let bpm = beats * 60 / interval
        return (20...300).contains(bpm) ? bpm : nil
    }
}
