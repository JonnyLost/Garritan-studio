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
    @Published public private(set) var hasGuideAudioTrack = false
    @Published public private(set) var isPreparingGuideAudio = false
    @Published public private(set) var guideAudioMessage: String?
    /// Eight low-resolution, lazily decoded filmstrip images (never full frames).
    @Published public private(set) var thumbnails: [Int: NSImage] = [:]

    private weak var transport: TransportState?
    private weak var guideAudioBus: StudioPictureGuideAudioBus?
    private var guideAudioTask: Task<Void, Never>?
    private var guidePreparationID = UUID()
    private var guideExporter: AVAssetExportSession?
    private var guideAudioURL: URL?
    private var subscriptions = Set<AnyCancellable>()
    private var currentDocument: StudioPictureProject?
    private var mediaTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var accessedURL: URL?
    private var isAccessingResource = false
    private var lastCorrectionUptime: TimeInterval = -.infinity
    private var lastProjectSeconds: Double?
    private var lastObservedUptime: TimeInterval?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailGenerator: AVAssetImageGenerator?

    public init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    public func bind(to transport: TransportState,
                     guideAudioBus: StudioPictureGuideAudioBus) {
        guard self.transport !== transport || self.guideAudioBus !== guideAudioBus else { return }
        subscriptions.removeAll()
        self.transport = transport
        self.guideAudioBus = guideAudioBus

        transport.$isPlaying
            // @Published emits the incoming value *before* isPlaying updates.
            // Use that incoming value so Pause freezes video immediately.
            .sink { [weak self, weak transport] playing in
                guard let self, let transport else { return }
                self.synchronize(at: Double(transport.playheadPosition.samples) /
                                 max(1, transport.sampleRate),
                                 playing: playing, force: true)
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
        clearGuideAudio()
        guideAudioBus = nil
        player.replaceCurrentItem(with: nil)
        currentDocument = nil
        isReady = false
        lastProjectSeconds = nil
        lastObservedUptime = nil
        releaseSecurityScopedURL()
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    /// Frequent unrelated Project changes must not reload or restart the movie.
    public func update(document: StudioPictureProject?) {
        let changedSource = document?.filePath != currentDocument?.filePath ||
            document?.securityBookmark != currentDocument?.securityBookmark ||
            document?.mediaRevisionID != currentDocument?.mediaRevisionID
        let changedAlignment = document?.timelineStartSeconds != currentDocument?.timelineStartSeconds ||
            document?.durationSeconds != currentDocument?.durationSeconds ||
            document?.frameRate != currentDocument?.frameRate
        let changedGuide = document?.referenceAudioEnabled != currentDocument?.referenceAudioEnabled ||
            document?.referenceAudioVolume != currentDocument?.referenceAudioVolume
        currentDocument = document
        // AVPlayer always presents *silent video*. Guide audio is owned by
        // the dedicated AudioEngine mixer, never played twice.
        player.isMuted = true
        updateGuideMix()
        if !changedSource {
            if changedGuide && document?.referenceAudioEnabled == true {
                requestGuideAudioIfNeeded()
            } else if changedGuide && document?.referenceAudioEnabled != true {
                cancelGuidePreparation()
            }
            if changedAlignment || changedGuide, let transport {
                synchronize(at: Double(transport.playheadPosition.samples) /
                            max(1, transport.sampleRate),
                            playing: transport.isPlaying, force: true)
            }
            return
        }

        mediaTask?.cancel()
        cancelThumbnails()
        clearGuideAudio()
        loadGeneration = UUID()
        let generation = loadGeneration
        player.pause()
        player.replaceCurrentItem(with: nil)
        lastProjectSeconds = nil
        lastObservedUptime = nil
        lastCorrectionUptime = -.infinity
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
            let guideTracks = try await asset.loadTracks(withMediaType: .audio)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            hasGuideAudioTrack = !guideTracks.isEmpty
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.isMuted = true
            isLoading = false
            isReady = true
            requestGuideAudioIfNeeded()
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

    /// The audio sample clock is the source of truth. Explicit locator jumps
    /// and loop wraps resynchronize immediately, while small normal playback
    /// jitter is absorbed without decoding/reseeking whole video frames.
    private func synchronize(at projectSeconds: Double, playing: Bool, force: Bool = false) {
        guard let document = currentDocument,
              let item = player.currentItem,
              projectSeconds.isFinite else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let jumped = StudioPictureSyncPlanner.isDiscontinuity(
            previousProjectSeconds: lastProjectSeconds,
            previousUptime: lastObservedUptime,
            currentProjectSeconds: projectSeconds, uptime: now)
        lastProjectSeconds = projectSeconds
        lastObservedUptime = now

        let actual = player.currentTime().seconds
        let decision = StudioPictureSyncPlanner.plan(
            picture: document,
            projectSeconds: projectSeconds,
            movieSeconds: actual.isFinite ? actual : nil,
            isPlaying: playing,
            secondsSinceCorrection: now - lastCorrectionUptime,
            discontinuity: force || jumped)

        if decision.shouldSeek {
            lastCorrectionUptime = now
            let position = CMTime(seconds: decision.targetSeconds, preferredTimescale: 60_000)
            item.cancelPendingSeeks()
            player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if decision.shouldPlay {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
        guideAudioBus?.synchronize(
            projectSeconds: projectSeconds,
            pictureStartSeconds: document.timelineStartSeconds,
            playing: playing, discontinuity: force || jumped)
    }

    private func updateGuideMix() {
        let active = currentDocument?.referenceAudioEnabled ?? false
        let volume = currentDocument?.referenceAudioVolume ?? 0.65
        guideAudioBus?.setMix(enabled: active, volume: volume)
    }

    /// Extract only when explicitly enabled. This leaves video-only scoring
    /// sessions battery-friendly and keeps potentially long production audio
    /// out of RAM. Compression remains in a disposable M4A scratch file.
    private func requestGuideAudioIfNeeded() {
        guard currentDocument?.referenceAudioEnabled == true,
              hasGuideAudioTrack, isReady,
              guideAudioURL == nil, guideAudioTask == nil,
              let asset = player.currentItem?.asset else { return }

        isPreparingGuideAudio = true
        guideAudioMessage = "Preparing reference dialogue…"
        let generation = loadGeneration
        let preparationID = UUID()
        guidePreparationID = preparationID
        guideAudioTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareGuideAudio(
                asset: asset, generation: generation, preparationID: preparationID)
        }
    }

    private func prepareGuideAudio(asset: AVAsset, generation: UUID,
                                   preparationID: UUID) async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-picture-guide-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer {
            if generation == loadGeneration && preparationID == guidePreparationID {
                guideAudioTask = nil
                isPreparingGuideAudio = false
                guideExporter = nil
            }
        }

        do {
            guard let exporter = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw StudioPictureGuideError.cannotExport
            }
            // Opt out of energy-intensive parallel encoding on a MacBook.
            exporter.allowsParallelizedExport = false
            exporter.outputURL = tempURL
            exporter.outputFileType = .m4a
            guideExporter = exporter

            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    if exporter.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: exporter.error ??
                            StudioPictureGuideError.cannotExport)
                    }
                }
            }

            guard generation == loadGeneration,
                  preparationID == guidePreparationID, !Task.isCancelled,
                  currentDocument?.referenceAudioEnabled == true,
                  let guideAudioBus else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            try guideAudioBus.load(fileURL: tempURL)
            guideAudioURL = tempURL
            guideAudioMessage = nil
            updateGuideMix()
            if let transport {
                synchronize(at: Double(transport.playheadPosition.samples) /
                            max(1, transport.sampleRate),
                            playing: transport.isPlaying, force: true)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            guard generation == loadGeneration,
                  preparationID == guidePreparationID, !Task.isCancelled else { return }
            guideAudioMessage = "Could not route movie audio through Studio: \(error.localizedDescription)"
        }
    }

    private func cancelGuidePreparation() {
        guidePreparationID = UUID()
        guideAudioTask?.cancel()
        guideAudioTask = nil
        guideExporter?.cancelExport()
        guideExporter = nil
        isPreparingGuideAudio = false
        guideAudioMessage = nil
    }

    private func clearGuideAudio() {
        cancelGuidePreparation()
        guideAudioBus?.clear()
        if let guideAudioURL {
            try? FileManager.default.removeItem(at: guideAudioURL)
        }
        guideAudioURL = nil
        hasGuideAudioTrack = false
        isPreparingGuideAudio = false
        guideAudioMessage = nil
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

public enum StudioPictureGuideError: LocalizedError {
    case cannotExport

    public var errorDescription: String? {
        "This movie's reference audio could not be extracted. Video scoring remains available."
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
