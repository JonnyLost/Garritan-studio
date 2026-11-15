import AppKit
import AVFoundation
import Combine
import DAWCore
import Foundation

/// The audio engine remains the only transport authority. Video decoding,
/// seeking and drift correction never run on the realtime audio thread.
@MainActor
public final class StudioPictureSession: ObservableObject {
    public let player = AVPlayer()
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isReady = false
    /// Eight low-resolution, lazily decoded filmstrip images (never full frames).
    @Published public private(set) var thumbnails: [Int: NSImage] = [:]

    private weak var transport: TransportState?
    private var subscriptions = Set<AnyCancellable>()
    private var currentDocument: StudioPictureProject?
    private var mediaTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var accessedURL: URL?
    private var isAccessingResource = false
    private var lastCorrection = Date.distantPast
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailGenerator: AVAssetImageGenerator?

    public init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    public func bind(to transport: TransportState) {
        guard self.transport !== transport else { return }
        subscriptions.removeAll()
        self.transport = transport

        transport.$isPlaying
            .sink { [weak self, weak transport] _ in
                guard let self, let transport else { return }
                self.synchronize(at: Double(transport.playheadPosition.samples) /
                                 max(1, transport.sampleRate),
                                 playing: transport.isPlaying, force: true)
            }
            .store(in: &subscriptions)
        transport.$playheadPosition
            .sink { [weak self, weak transport] position in
                guard let self, let transport else { return }
                self.synchronize(at: Double(position.samples) /
                                 max(1, transport.sampleRate),
                                 playing: transport.isPlaying)
            }
            .store(in: &subscriptions)
    }

    public func unbind() {
        subscriptions.removeAll()
        transport = nil
        player.pause()
        mediaTask?.cancel()
        cancelThumbnails()
        releaseSecurityScopedURL()
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    /// Frequent unrelated Project changes must not reload or restart the movie.
    public func update(document: StudioPictureProject?) {
        let changedSource = document?.filePath != currentDocument?.filePath ||
            document?.securityBookmark != currentDocument?.securityBookmark
        currentDocument = document
        player.isMuted = !(document?.referenceAudioEnabled ?? false)
        guard changedSource else { return }

        mediaTask?.cancel()
        cancelThumbnails()
        loadGeneration = UUID()
        let generation = loadGeneration
        player.pause()
        player.replaceCurrentItem(with: nil)
        releaseSecurityScopedURL()
        isReady = false
        errorMessage = nil

        guard let document else {
            isLoading = false
            return
        }

        isLoading = true
        mediaTask = Task { [weak self] in
            guard let self else { return }
            await self.load(document: document, generation: generation)
        }
    }

    private func load(document: StudioPictureProject, generation: UUID) async {
        var url = URL(fileURLWithPath: document.filePath)
        if let bookmark = document.securityBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark,
                                       options: [.withSecurityScope],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &stale) {
                url = resolved
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            if generation == loadGeneration {
                isLoading = false
                errorMessage = "The movie file could not be found. Choose Relink to locate it."
            }
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        guard generation == loadGeneration, !Task.isCancelled else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        accessedURL = url
        isAccessingResource = accessing

        do {
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            guard playable else {
                throw StudioPictureMediaError.unsupported
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                throw StudioPictureMediaError.noVideo
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.isMuted = !document.referenceAudioEnabled
            isLoading = false
            isReady = true
            if let transport {
                synchronize(at: Double(transport.playheadPosition.samples) /
                            max(1, transport.sampleRate),
                            playing: transport.isPlaying, force: true)
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            isLoading = false
            isReady = false
            errorMessage = error.localizedDescription
            releaseSecurityScopedURL()
        }
    }

    /// Only decode previews while a scoring viewport is actually displayed.
    public func requestThumbnails() {
        guard isReady, thumbnails.isEmpty, thumbnailTask == nil,
              let asset = player.currentItem?.asset,
              let document = currentDocument else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        thumbnailGenerator = generator
        let generation = loadGeneration
        thumbnailTask = Task { [weak self] in
            for index in 0..<8 {
                guard !Task.isCancelled else { break }
                let seconds = document.durationSeconds * (Double(index) + 0.5) / 8
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let frame = try? await generator.image(at: time).image {
                    guard let self, self.loadGeneration == generation else { break }
                    self.thumbnails[index] = NSImage(
                        cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                }
            }
            if let self, self.loadGeneration == generation {
                self.thumbnailTask = nil
            }
        }
    }

    private func cancelThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailGenerator?.cancelAllCGImageGeneration()
        thumbnailGenerator = nil
        thumbnails.removeAll()
    }

    /// Synchronize from the DAW sample clock. A coarse seek is used only for
    /// material video drift; repeated frame seeks would hurt decode performance.
    private func synchronize(at projectSeconds: Double, playing: Bool, force: Bool = false) {
        guard let document = currentDocument,
              player.currentItem != nil,
              projectSeconds.isFinite else { return }

        let relative = projectSeconds - document.timelineStartSeconds
        let duration = document.durationSeconds
        let inRange = relative >= 0 && relative < duration
        let wanted = max(0, min(max(0, duration - 1 / document.frameRate.framesPerSecond),
                                relative))
        let tolerance = 1 / document.frameRate.framesPerSecond
        let actual = player.currentTime().seconds
        let deviation = actual.isFinite ? abs(actual - wanted) : Double.infinity
        let canCorrect = force || Date().timeIntervalSince(lastCorrection) > 0.75
        let threshold = playing ? max(0.06, 1.5 * tolerance) : tolerance

        if canCorrect && (force || deviation > threshold) {
            lastCorrection = Date()
            let position = CMTime(seconds: wanted, preferredTimescale: 60_000)
            player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if playing && inRange {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    private func releaseSecurityScopedURL() {
        if isAccessingResource { accessedURL?.stopAccessingSecurityScopedResource() }
        accessedURL = nil
        isAccessingResource = false
    }

    deinit {
        mediaTask?.cancel()
        // Deinit doesn't touch AVPlayer or NS security-scope APIs off-main.
        // Main-window lifecycle invokes unbind() while still on MainActor.
    }
}

public enum StudioPictureMediaError: LocalizedError {
    case unsupported, noVideo

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "macOS cannot decode this movie. Try an H.264 MP4 or a ProRes MOV."
        case .noVideo:
            return "The selected file has no video track."
        }
    }
}
