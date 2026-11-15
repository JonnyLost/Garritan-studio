import AVFoundation
import Combine
import Foundation

/// Combines an already-rendered Studio WAV with the original picture without
/// invoking or changing Studio's live audio/MIDI transport.
@MainActor
public final class StudioPictureMovieExporter: ObservableObject {
    @Published public private(set) var isExporting = false
    @Published public private(set) var status = ""
    @Published public private(set) var progress: Double = 0

    private var exporter: AVAssetExportSession?
    private var stagedOutput: URL?
    private var progressTask: Task<Void, Never>?

    public init() {}

    /// An explicit post-mix workflow: bounce Stereo Mix to WAV first, then
    /// select that mix for the movie. Guide audio is separately optional.
    ///
    /// The WAV and picture are trimmed to the visible movie's duration. The
    /// picture starts at zero, while the WAV is read starting at its project
    /// offset, so a score that began at a later Studio bar stays aligned.
    public func export(picture: StudioPictureProject,
                       scoreURL: URL,
                       destination: URL,
                       includeReferenceAudio: Bool,
                       referenceGain: Float = 0.65) async throws {
        guard !isExporting else { throw StudioPictureMovieExportError.busy }
        guard picture.durationSeconds.isFinite, picture.durationSeconds > 0,
              picture.timelineStartSeconds.isFinite,
              picture.timelineStartSeconds >= 0 else {
            throw StudioPictureMovieExportError.invalidAlignment
        }
        guard scoreURL.standardizedFileURL != destination.standardizedFileURL,
              URL(fileURLWithPath: picture.filePath).standardizedFileURL != destination.standardizedFileURL else {
            throw StudioPictureMovieExportError.destinationConflictsWithSource
        }

        isExporting = true
        progress = 0
        status = "Preparing picture and score…"
        defer {
            exporter = nil
            progressTask?.cancel()
            progressTask = nil
            isExporting = false
        }

        var pictureURL = URL(fileURLWithPath: picture.filePath)
        if let data = picture.securityBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data,
                                       options: [.withSecurityScope],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                pictureURL = resolved
            }
        }
        let usesPictureScope = pictureURL.startAccessingSecurityScopedResource()
        defer {
            if usesPictureScope { pictureURL.stopAccessingSecurityScopedResource() }
        }
        let usesScoreScope = scoreURL.startAccessingSecurityScopedResource()
        defer {
            if usesScoreScope { scoreURL.stopAccessingSecurityScopedResource() }
        }

        let movie = AVURLAsset(url: pictureURL)
        let score = AVURLAsset(url: scoreURL)
        let sourceVideo = try await movie.loadTracks(withMediaType: .video)
        guard let video = sourceVideo.first else {
            throw StudioPictureMovieExportError.missingVideo
        }
        let sourceScore = try await score.loadTracks(withMediaType: .audio)
        guard let scoreTrack = sourceScore.first else {
            throw StudioPictureMovieExportError.missingScoreAudio
        }

        let movieDuration = try await movie.load(.duration)
        let scoreDuration = try await score.load(.duration)
        let movieSeconds = movieDuration.seconds
        let scoreSeconds = scoreDuration.seconds
        guard movieSeconds.isFinite && movieSeconds > 0,
              scoreSeconds.isFinite && scoreSeconds > picture.timelineStartSeconds else {
            throw StudioPictureMovieExportError.scoreDoesNotOverlapMovie
        }

        let composition = AVMutableComposition()
        let videoTrack = try XCTlessTrack(composition, mediaType: .video)
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: movieDuration),
            of: video, at: .zero)
        videoTrack.preferredTransform = try await video.load(.preferredTransform)

        let audioMix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []

        let overlap = min(movieSeconds, scoreSeconds - picture.timelineStartSeconds)
        let scoreTime = CMTime(seconds: picture.timelineStartSeconds,
                               preferredTimescale: 60_000)
        let overlapTime = CMTime(seconds: overlap, preferredTimescale: 60_000)
        let compositionScore = try XCTlessTrack(composition, mediaType: .audio)
        try compositionScore.insertTimeRange(
            CMTimeRange(start: scoreTime, duration: overlapTime),
            of: scoreTrack, at: .zero)
        let scoreParams = AVMutableAudioMixInputParameters(track: compositionScore)
        scoreParams.setVolume(1, at: .zero)
        parameters.append(scoreParams)

        if includeReferenceAudio {
            let sourceAudio = try await movie.loadTracks(withMediaType: .audio)
            if let source = sourceAudio.first {
                let production = try XCTlessTrack(composition, mediaType: .audio)
                // The picture's guide audio may be shorter than its video.
                // Never request source frames beyond the audio track's range.
                let sourceRange = try await source.load(.timeRange)
                let guideDuration = CMTimeMinimum(movieDuration, sourceRange.duration)
                guard guideDuration.isValid && guideDuration.seconds > 0 else {
                    throw StudioPictureMovieExportError.invalidReferenceAudio
                }
                try production.insertTimeRange(
                    CMTimeRange(start: sourceRange.start, duration: guideDuration),
                    of: source, at: .zero)
                let guideParams = AVMutableAudioMixInputParameters(track: production)
                let safeGain: Float = referenceGain.isFinite
                    ? min(1, max(0, referenceGain)) : 0.65
                guideParams.setVolume(safeGain, at: .zero)
                parameters.append(guideParams)
            }
        }
        audioMix.inputParameters = parameters

        let stageURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".studio-picture-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        stagedOutput = stageURL
        defer {
            try? FileManager.default.removeItem(at: stageURL)
            stagedOutput = nil
        }
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StudioPictureMovieExportError.cannotCreateSession
        }
        guard session.supportedFileTypes.contains(.mov) else {
            throw StudioPictureMovieExportError.unsupportedOutput
        }
        session.outputURL = stageURL
        session.outputFileType = .mov
        session.audioMix = audioMix
        session.shouldOptimizeForNetworkUse = false
        exporter = session
        status = "Writing scored movie…"
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.progress = Double(session.progress)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error ??
                        StudioPictureMovieExportError.exportFailed)
                }
            }
        }
        try Task.checkCancellation()
        guard session.status == .completed,
              FileManager.default.fileExists(atPath: stageURL.path) else {
            throw StudioPictureMovieExportError.exportFailed
        }
        // Never destroy an existing export or source file on failed re-export.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StudioPictureMovieExportError.destinationExists
        }
        try FileManager.default.moveItem(at: stageURL, to: destination)
        progress = 1
        status = "Scored movie exported"
    }

    public func cancel() {
        exporter?.cancelExport()
        progressTask?.cancel()
    }

    private func XCTlessTrack(_ composition: AVMutableComposition,
                              mediaType: AVMediaType) throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(withMediaType: mediaType,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw StudioPictureMovieExportError.cannotCreateSession }
        return track
    }
}

public enum StudioPictureMovieExportError: LocalizedError {
    case busy, invalidAlignment, destinationConflictsWithSource
    case missingVideo, missingScoreAudio, scoreDoesNotOverlapMovie, invalidReferenceAudio
    case cannotCreateSession, unsupportedOutput, exportFailed, destinationExists

    public var errorDescription: String? {
        switch self {
        case .busy: return "A movie export is already running."
        case .invalidAlignment: return "The project's picture offset is invalid."
        case .destinationConflictsWithSource:
            return "Choose a new destination; a source movie or WAV cannot be overwritten."
        case .missingVideo: return "The reference movie does not contain a video track."
        case .missingScoreAudio: return "Choose a rendered Studio WAV containing audio."
        case .invalidReferenceAudio: return "The original picture audio track has no usable duration."
        case .scoreDoesNotOverlapMovie:
            return "The Studio mix ends before the movie starts at its saved picture offset."
        case .cannotCreateSession: return "macOS could not create a movie export session."
        case .unsupportedOutput: return "This movie cannot be exported as a QuickTime MOV."
        case .exportFailed: return "macOS did not complete the scored movie export."
        case .destinationExists: return "A movie already exists at the selected destination."
        }
    }
}
