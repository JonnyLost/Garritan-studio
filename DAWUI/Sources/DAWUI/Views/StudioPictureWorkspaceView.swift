import AppKit
import AVFoundation
import AVKit
import DAWCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared native movie surface. There is exactly one visible player surface
/// whether the editor is docked or detached.
struct StudioPicturePlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

@MainActor
final class StudioPictureFloatingWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(content: StudioPictureWorkspaceView) {
        let window = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Studio Picture"
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: content)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("Studio Picture floating windows are created programmatically.")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Film scoring controls live alongside the existing lower workspaces.
public struct StudioPictureWorkspaceView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    @ObservedObject private var session: StudioPictureSession
    @ObservedObject private var transport: TransportState

    private let floating: Bool
    private let toggleFloating: () -> Void

    @State private var newHitName = ""
    @State private var showingNewHit = false
    @State private var showingMovieExport = false
    @State private var editingHit: StudioPictureHitPoint?
    @State private var startCodeDraft = ""
    @State private var locateCodeDraft = ""
    @State private var cueSearch = ""
    @State private var cueKindFilter = "all"
    @State private var tempoSpanBeats = 8.0

    public init(viewModel: ProjectViewModel, session: StudioPictureSession,
                floating: Bool, toggleFloating: @escaping () -> Void) {
        self.viewModel = viewModel
        self.session = session
        self.transport = viewModel.transportState
        self.floating = floating
        self.toggleFloating = toggleFloating
    }

    public var body: some View {
        VStack(spacing: 0) {
            StudioWorkspaceHeader(
                "Studio Picture",
                subtitle: "Movie playback, SMPTE timecode and orchestral hit points",
                symbol: "film"
            ) {
                Button("Import Movie") { chooseMovie(relink: false) }
                Button {
                    toggleFloating()
                } label: {
                    Label(floating ? "Dock" : "Float",
                          systemImage: floating ? "rectangle.inset.filled" : "macwindow.on.rectangle")
                }
                .help(floating ? "Dock picture in the lower workspace" : "Open a resizable picture window")
            }

            if let picture = viewModel.project.studioPicture {
                pictureContent(picture)
            } else {
                ContentUnavailableView {
                    Label("No Reference Picture", systemImage: "film")
                } description: {
                    Text("Import a movie to compose directly to picture.")
                } actions: {
                    Button("Import Movie") { chooseMovie(relink: false) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Add Hit Point", isPresented: $showingNewHit) {
            TextField("Cue name", text: $newHitName)
            Button("Add") { addHitPoint() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The cue is stored at the exact movie frame under the playhead.")
        }
        .sheet(isPresented: $showingMovieExport) {
            if let picture = viewModel.project.studioPicture {
                StudioPictureMovieExportView(picture: picture)
            }
        }
        .sheet(item: $editingHit) { hit in
            if let picture = viewModel.project.studioPicture {
                StudioPictureHitEditor(hit: hit, picture: picture) { edited in
                    updatePicture { document in
                        guard let index = document.hitPoints.firstIndex(where: { $0.id == edited.id }) else { return }
                        document.hitPoints[index] = edited
                    }
                }
            }
        }
        .onAppear {
            session.requestThumbnails()
            if let picture = viewModel.project.studioPicture {
                startCodeDraft = picture.timecode(atMovieFrame: 0)
            }
        }
        .onChange(of: session.isReady) { _, ready in
            if ready { session.requestThumbnails() }
        }
        .onChange(of: viewModel.project.studioPicture?.startTimecodeFrame) { _, _ in
            if let picture = viewModel.project.studioPicture {
                startCodeDraft = picture.timecode(atMovieFrame: 0)
            }
        }
    }

    @ViewBuilder
    private func pictureContent(_ picture: StudioPictureProject) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    StudioPicturePlayerSurface(player: session.player)
                    if let cue = StudioPictureCueVisualPlanner.visual(
                        picture: picture, projectSeconds: currentProjectSeconds()) {
                        StudioPictureCueOverlay(cue: cue)
                            .allowsHitTesting(false)
                    }
                    if picture.showTimecodeOverlay ?? true {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Text(picture.timecode(atMovieFrame: currentFrame(picture)))
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.7))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(12)
                        .allowsHitTesting(false)
                    }
                    if session.isLoading {
                        ProgressView("Loading picture…")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 8) {
                    Button {
                        goToAdjacentHit(direction: -1, picture: picture)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("Previous hit point")
                    Button { stepFrame(-1, picture: picture) } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .help("Previous picture frame")
                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .help("Play or pause Studio's transport")
                    Button { stepFrame(1, picture: picture) } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .help("Next picture frame")
                    Button {
                        goToAdjacentHit(direction: 1, picture: picture)
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .help("Next hit point")

                    Text(picture.timecode(atMovieFrame: currentFrame(picture)))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 116)

                    Spacer()
                    Text(picture.frameRate.displayName + " fps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        newHitName = "Hit \(picture.hitPoints.count + 1)"
                        showingNewHit = true
                    } label: {
                        Label("Add Hit", systemImage: "mappin.and.ellipse")
                    }
                }
                .buttonStyle(.borderless)

                StudioPictureScrubber(
                    picture: picture,
                    thumbnails: session.thumbnails,
                    playheadFrame: currentFrame(picture),
                    seek: { seek(toMovieFrame: $0, picture: picture) }
                )
                .frame(height: 62)

                if let message = session.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.caption).lineLimit(2)
                        Spacer()
                        Button("Relink") { chooseMovie(relink: true) }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.08))
                    .cornerRadius(6)
                }
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(picture.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack {
                        Text("Frame rate")
                        Spacer()
                        Picker("Frame rate", selection: Binding(
                            get: { picture.frameRate },
                            set: { newRate in
                                updatePicture { updated in
                                    let oldStart = picture.timecode(atMovieFrame: 0)
                                    updated.frameRate = newRate
                                    updated.startTimecodeFrame = StudioPictureTimecode.frameNumber(
                                        oldStart, rate: newRate) ?? 0
                                }
                            }
                        )) {
                            ForEach(StudioPictureFrameRate.allCases) { rate in
                                Text(rate.displayName).tag(rate)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 115)
                    }
                    if session.hasEmbeddedTimecodeTrack {
                        Label("Embedded SMPTE track detected", systemImage: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Start TC remains manual until the source timecode sample is verified.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Start TC")
                        TextField("01:00:00:00", text: $startCodeDraft)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyStartTimecode(picture) }
                        Button("Set") { applyStartTimecode(picture) }
                            .buttonStyle(.borderless)
                    }
                    HStack(spacing: 6) {
                        TextField("Go to SMPTE", text: $locateCodeDraft)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { goToTimecode(picture) }
                            .accessibilityLabel("Locate picture SMPTE frame")
                        Button("Go") { goToTimecode(picture) }
                            .buttonStyle(.borderless)
                        Button {
                            locateCodeDraft = picture.timecode(atMovieFrame: currentFrame(picture))
                        } label: {
                            Image(systemName: "scope")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy current picture timecode into locator")
                    }
                    HStack {
                        Text("Picture offset")
                        TextField("Seconds", value: Binding(
                            get: { picture.timelineStartSeconds },
                            set: { value in updatePicture { $0.timelineStartSeconds = max(0, value) } }
                        ), format: .number.precision(.fractionLength(2)))
                            .frame(width: 75)
                            .textFieldStyle(.roundedBorder)
                        Text("sec").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Toggle("Guide audio", isOn: Binding(
                            get: { picture.referenceAudioEnabled },
                            set: { enabled in updatePicture { $0.referenceAudioEnabled = enabled } }
                        ))
                        .font(.caption)
                        Spacer()
                        if !session.hasGuideAudioTrack {
                            Text("No audio track")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(picture.referenceAudioVolume ?? 0.65) },
                            set: { newValue in
                                updatePicture { $0.referenceAudioVolume = Float(newValue) }
                            }
                        ), in: 0...1)
                        .disabled(!picture.referenceAudioEnabled)
                        Text(String(format: "%.0f%%", (picture.referenceAudioVolume ?? 0.65) * 100))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                    if session.isPreparingGuideAudio {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Preparing guide audio")
                                .font(.caption2)
                        }
                    } else if let message = session.guideAudioMessage {
                        Text(message).font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text("Dialogue follows Studio's audio engine and is excluded from score exports.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("Timecode overlay", isOn: Binding(
                        get: { picture.showTimecodeOverlay ?? true },
                        set: { enabled in updatePicture { $0.showTimecodeOverlay = enabled } }
                    ))
                    .font(.caption)
                    Divider()
                    Text("Scoring Cues").font(.subheadline.weight(.semibold))
                    Toggle("Show streamers", isOn: Binding(
                        get: { picture.showScoringStreamers ?? true },
                        set: { enabled in updatePicture { $0.showScoringStreamers = enabled } }
                    ))
                    .font(.caption)
                    Toggle("Flash punch at hit", isOn: Binding(
                        get: { picture.showScoringPunches ?? true },
                        set: { enabled in updatePicture { $0.showScoringPunches = enabled } }
                    ))
                    .font(.caption)
                    HStack {
                        Text("Streamer lead")
                            .font(.caption)
                        Spacer()
                        Picker("Streamer lead", selection: Binding(
                            get: { picture.streamerLeadSeconds ?? 3 },
                            set: { seconds in updatePicture { $0.streamerLeadSeconds = seconds } }
                        )) {
                            Text("1 second").tag(1.0)
                            Text("2 seconds").tag(2.0)
                            Text("3 seconds").tag(3.0)
                            Text("5 seconds").tag(5.0)
                        }
                        .labelsHidden()
                        .frame(width: 115)
                    }

                    HStack {
                        Text("Hit Points")
                            .font(.headline)
                        Spacer()
                        Text("\(picture.hitPoints.count)")
                            .foregroundStyle(.secondary)
                        Button {
                            newHitName = "Hit \(picture.hitPoints.count + 1)"
                            showingNewHit = true
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                    }
                    HStack(spacing: 6) {
                        TextField("Find cue, note, timecode", text: $cueSearch)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .accessibilityLabel("Filter picture hit points")
                        Picker("Cue type", selection: $cueKindFilter) {
                            Text("All").tag("all")
                            ForEach(StudioPictureHitKind.allCases) { kind in
                                Text(kind.label).tag(kind.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    let visibleHits = StudioPictureCueNavigation.matching(
                        picture, query: cueSearch, kind: selectedCueKind)
                    Text("\(visibleHits.count) of \(picture.hitPoints.count) cues")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Divider()
                    ForEach(visibleHits) { hit in
                        HStack(spacing: 6) {
                            Button {
                                seek(toMovieFrame: hit.frame, picture: picture)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.name).font(.caption.weight(.medium))
                                    HStack(spacing: 5) {
                                        Text(hit.kind.label)
                                        Text(picture.timecode(atMovieFrame: hit.frame))
                                    }
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    if !hit.notes.isEmpty {
                                        Text(hit.notes)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button("Edit Cue…") { editingHit = hit }
                                Divider()
                                ForEach(StudioPictureHitKind.allCases) { kind in
                                    Button(kind.label) {
                                        updatePicture { p in
                                            guard let index = p.hitPoints.firstIndex(where: { $0.id == hit.id }) else { return }
                                            p.hitPoints[index].kind = kind
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete Hit Point", role: .destructive) {
                                    updatePicture { $0.hitPoints.removeAll(where: { $0.id == hit.id }) }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 20)
                        }
                    }
                    if picture.hitPoints.isEmpty {
                        Text("Add a hit at any key frame, cut or dramatic moment.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        if visibleHits.isEmpty {
                            Text("No cues match these filters.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            exportCueSheet(picture)
                        } label: {
                            Label("Export Cue Sheet…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .help("Create a CSV cue sheet with SMPTE, picture frames, and notes")
                    }
                    if picture.hitPoints.count >= 2 {
                        Divider()
                        Text("Hit Point Tempo Finder").font(.subheadline.weight(.semibold))
                        Picker("Beats between hits", selection: $tempoSpanBeats) {
                            Text("4 beats").tag(4.0)
                            Text("8 beats").tag(8.0)
                            Text("16 beats").tag(16.0)
                        }
                        .pickerStyle(.segmented)
                        let sorted = picture.hitPoints.sorted(by: { $0.frame < $1.frame })
                        if let first = sorted.first, let last = sorted.last,
                           let suggested = picture.suggestedTempo(from: first, to: last,
                                                                  beats: tempoSpanBeats) {
                            Text(String(format: "Suggested: %.2f BPM", suggested))
                                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                            Text("Suggestion only; existing MIDI and tempo are unchanged.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                    Button {
                        showingMovieExport = true
                    } label: {
                        Label("Export Scored Movie…", systemImage: "film.stack")
                    }
                    .buttonStyle(.bordered)
                    Button("Relink Movie…") { chooseMovie(relink: true) }
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .frame(width: 260)
        }
        .padding(12)
    }

    private func currentProjectSeconds() -> Double {
        Double(transport.playheadPosition.samples) / max(1, transport.sampleRate)
    }

    private func currentFrame(_ picture: StudioPictureProject) -> Int64 {
        picture.movieFrame(atProjectSeconds: currentProjectSeconds())
    }

    private func seek(toMovieFrame frame: Int64, picture: StudioPictureProject) {
        let seconds = picture.projectSeconds(atMovieFrame: frame)
        let bpm = transport.tempo.bpm
        // Matches the current transport's TimePosition(beats:tempo:) mapping.
        viewModel.seekTo(beat: seconds * bpm / 60)
    }

    private var selectedCueKind: StudioPictureHitKind? {
        cueKindFilter == "all" ? nil : StudioPictureHitKind(rawValue: cueKindFilter)
    }

    private func goToTimecode(_ picture: StudioPictureProject) {
        guard let frame = StudioPictureCueNavigation.frame(
            forEnteredTimecode: locateCodeDraft, picture: picture) else {
            session.reportError(StudioPictureImportError.invalidLocator)
            return
        }
        if transport.isPlaying { viewModel.togglePlayPause() }
        seek(toMovieFrame: frame, picture: picture)
    }

    private func goToAdjacentHit(direction: Int, picture: StudioPictureProject) {
        guard let hit = StudioPictureCueNavigation.adjacent(
            picture, currentFrame: currentFrame(picture), direction: direction,
            query: cueSearch, kind: selectedCueKind) else { return }
        seek(toMovieFrame: hit.frame, picture: picture)
    }

    private func exportCueSheet(_ picture: StudioPictureProject) {
        let panel = NSSavePanel()
        panel.title = "Export Studio Picture Cue Sheet"
        panel.allowedContentTypes = [.commaSeparatedText]
        let base = (picture.filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "-cue-sheet.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try StudioPictureCueSheet.csv(for: picture).write(
                to: url, atomically: true, encoding: .utf8)
        } catch {
            session.reportError(error)
        }
    }

    private func stepFrame(_ delta: Int64, picture: StudioPictureProject) {
        if transport.isPlaying { viewModel.togglePlayPause() }
        seek(toMovieFrame: max(0, min(max(0, picture.totalFrames - 1),
                                     currentFrame(picture) + delta)), picture: picture)
    }

    private func addHitPoint() {
        guard var picture = viewModel.project.studioPicture else { return }
        let name = newHitName.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = StudioPictureHitPoint(name: name.isEmpty ? "Hit Point" : name,
                                          frame: currentFrame(picture))
        picture.hitPoints.append(point)
        viewModel.project.studioPicture = picture
    }

    private func updatePicture(_ change: (inout StudioPictureProject) -> Void) {
        guard var picture = viewModel.project.studioPicture else { return }
        change(&picture)
        viewModel.project.studioPicture = picture
    }

    private func applyStartTimecode(_ picture: StudioPictureProject) {
        guard let frame = StudioPictureTimecode.frameNumber(startCodeDraft,
                                                            rate: picture.frameRate) else {
            session.reportError(StudioPictureImportError.invalidTimecode)
            return
        }
        updatePicture { $0.startTimecodeFrame = frame }
    }

    private func chooseMovie(relink: Bool) {
        let panel = NSOpenPanel()
        panel.title = relink ? "Relink Reference Picture" : "Import Reference Picture"
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else {
                    throw StudioPictureMediaError.unsupported
                }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    throw StudioPictureMediaError.noVideo
                }
                let duration = try await asset.load(.duration).seconds
                let fps = Double((try? await track.load(.nominalFrameRate)) ?? 24)
                guard duration.isFinite && duration > 0 else {
                    throw StudioPictureImportError.invalidDuration
                }
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
                if relink, var current = viewModel.project.studioPicture {
                    current.filename = url.lastPathComponent
                    current.filePath = url.path
                    current.securityBookmark = bookmark
                    current.mediaRevisionID = UUID()
                    // Preserve picture's cue mapping and SMPTE configuration.
                    current.durationSeconds = duration
                    viewModel.project.studioPicture = current
                } else {
                    let rate = StudioPictureFrameRate.closest(to: fps)
                    viewModel.project.studioPicture = StudioPictureProject(
                        url: url, durationSeconds: duration, frameRate: rate,
                        securityBookmark: bookmark)
                }
                if let current = viewModel.project.studioPicture {
                    startCodeDraft = current.timecode(atMovieFrame: 0)
                }
            } catch {
                session.reportError(error)
            }
        }
    }
}

/// Lightweight scoring streamer, anchored in picture-frame time. The moving
/// bar sweeps from the left edge and lands exactly on the selected hit frame.
/// A one-frame punch is overlaid without altering the media itself.
private struct StudioPictureCueOverlay: View {
    let cue: StudioPictureCueVisual

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if cue.isPunch {
                    Color.white.opacity(0.22)
                    Circle()
                        .strokeBorder(.white, lineWidth: 8)
                        .frame(width: min(proxy.size.width, proxy.size.height) * 0.4)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                } else {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 7)
                        .shadow(color: .black.opacity(0.85), radius: 5)
                        .position(x: max(4, min(proxy.size.width - 4,
                                                proxy.size.width * cue.progress)),
                                  y: proxy.size.height / 2)
                }
                VStack {
                    HStack {
                        Text(cue.name)
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(12)
            }
        }
        .accessibilityLabel(cue.isPunch ? "Scoring punch: \(cue.name)" :
            "Scoring streamer approaching \(cue.name)")
    }
}

private enum StudioPictureImportError: LocalizedError {
    case invalidTimecode, invalidDuration, invalidLocator

    var errorDescription: String? {
        switch self {
        case .invalidTimecode: return "Enter a valid SMPTE timecode for the selected frame rate."
        case .invalidDuration: return "This movie does not have a usable duration."
        case .invalidLocator: return "That SMPTE frame is invalid or outside the movie."
        }
    }
}

/// A lightweight film ruler with frame-based hit markers and scrubbing.
private struct StudioPictureScrubber: View {
    let picture: StudioPictureProject
    let thumbnails: [Int: NSImage]
    let playheadFrame: Int64
    let seek: (Int64) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let denominator = max(1, picture.totalFrames - 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { index in
                        Group {
                            if let image = thumbnails[index] {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                Color.black.opacity(0.18)
                            }
                        }
                        .frame(width: width / 8, height: 62)
                        .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(0.65)
                ForEach(picture.hitPoints) { hit in
                    Rectangle()
                        .fill(.orange)
                        .frame(width: 2, height: 48)
                        .offset(x: CGFloat(hit.frame) / CGFloat(denominator) * width)
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 58)
                    .offset(x: CGFloat(playheadFrame) / CGFloat(denominator) * width)
                HStack {
                    Text(picture.timecode(atMovieFrame: 0))
                    Spacer()
                    Text(picture.timecode(atMovieFrame: max(0, picture.totalFrames - 1)))
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .offset(y: 19)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let fraction = max(0, min(1, gesture.location.x / width))
                seek(Int64((fraction * CGFloat(denominator)).rounded()))
            })
        }
    }
}

private struct StudioPictureHitEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let original: StudioPictureHitPoint
    private let picture: StudioPictureProject
    private let onSave: (StudioPictureHitPoint) -> Void

    @State private var name: String
    @State private var kind: StudioPictureHitKind
    @State private var timecode: String
    @State private var notes: String
    @State private var validationMessage: String?

    init(hit: StudioPictureHitPoint, picture: StudioPictureProject,
         onSave: @escaping (StudioPictureHitPoint) -> Void) {
        self.original = hit
        self.picture = picture
        self.onSave = onSave
        _name = State(initialValue: hit.name)
        _kind = State(initialValue: hit.kind)
        _timecode = State(initialValue: picture.timecode(atMovieFrame: hit.frame))
        _notes = State(initialValue: hit.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Edit Picture Hit Point", systemImage: "mappin.and.ellipse")
                .font(.headline)
            Form {
                TextField("Cue name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(StudioPictureHitKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                TextField("SMPTE frame", text: $timecode)
                    .font(.system(.body, design: .monospaced))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Director or composer notes").font(.caption)
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                        .border(.secondary.opacity(0.2))
                }
            }
            .formStyle(.grouped)
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Cue") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 310)
    }

    private func save() {
        guard let movieFrame = picture.movieFrame(forTimecode: timecode) else {
            validationMessage = "Enter a valid timecode within the imported movie."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Please name this cue."
            return
        }
        var edited = original
        edited.name = trimmed
        edited.kind = kind
        edited.frame = movieFrame
        edited.notes = notes
        onSave(edited)
        dismiss()
    }
}
