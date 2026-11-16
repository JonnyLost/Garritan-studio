import Foundation

/// Pure arithmetic used by the file-backed Studio Picture reference channel.
/// This is intentionally independent from AVAudioEngine and can be regression
/// tested without requiring a Mac audio device.
public struct StudioPictureGuideSchedule: Equatable, Sendable {
    public let startingFrame: Int64
    public let frameCount: UInt32

    public init(startingFrame: Int64, frameCount: UInt32) {
        self.startingFrame = startingFrame
        self.frameCount = frameCount
    }
}

public enum StudioPictureGuideScheduler {
    /// Return the correct source frame in the decoded audio file.
    /// Picture's project offset is applied once and only once.
    public static func segment(
        projectSeconds: Double,
        pictureStartSeconds: Double,
        fileSampleRate: Double,
        totalFrames: Int64
    ) -> StudioPictureGuideSchedule? {
        guard projectSeconds.isFinite, pictureStartSeconds.isFinite,
              fileSampleRate.isFinite, fileSampleRate > 0,
              totalFrames > 0 else { return nil }

        let offset = projectSeconds - pictureStartSeconds
        guard offset >= 0 else { return nil }
        let frameDouble = (offset * fileSampleRate).rounded(.down)
        guard frameDouble.isFinite, frameDouble >= 0,
              frameDouble < Double(totalFrames),
              frameDouble < Double(Int64.max) else { return nil }
        let start = Int64(frameDouble)
        let remaining = totalFrames - start
        guard remaining > 0 else { return nil }
        return StudioPictureGuideSchedule(
            startingFrame: start,
            frameCount: UInt32(min(Int64(UInt32.max), remaining)))
    }
}
