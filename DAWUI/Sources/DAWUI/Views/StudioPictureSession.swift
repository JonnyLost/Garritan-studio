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

    private weak var transport: TransportState?
    private var subscriptions = Set<AnyCancellable>()
    private var currentDocument: StudioPictureProject?
    private var mediaTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var accessedURL: URL?
    private var isAccessingResource = false
    private var lastCorrection = Date.distantPast

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
        let canCorrect = force || Date().timeIntervalSince(lastCorrection) > 0.4
        let threshold = playing ? max(0.12, 4 * tolerance) : tolerance

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
