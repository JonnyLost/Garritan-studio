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
    @State private var startCodeDraft = ""
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
        .onAppear {
            if let picture = viewModel.project.studioPicture {
                startCodeDraft = picture.timecode(atMovieFrame: 0)
            }
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
                    HStack {
                        Text("Start TC")
                        TextField("01:00:00:00", text: $startCodeDraft)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyStartTimecode(picture) }
                        Button("Set") { applyStartTimecode(picture) }
                            .buttonStyle(.borderless)
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
                    Toggle("Play guide audio", isOn: Binding(
                        get: { picture.referenceAudioEnabled },
                        set: { enabled in updatePicture { $0.referenceAudioEnabled = enabled } }
                    ))
                    .font(.caption)

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
                    Divider()
                    ForEach(picture.hitPoints.sorted(by: { $0.frame < $1.frame })) { hit in
                        HStack(spacing: 6) {
                            Button {
                                seek(toMovieFrame: hit.frame, picture: picture)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.name).font(.caption.weight(.medium))
                                    Text(picture.timecode(atMovieFrame: hit.frame))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Menu {
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

private enum StudioPictureImportError: LocalizedError {
    case invalidTimecode, invalidDuration

    var errorDescription: String? {
        switch self {
        case .invalidTimecode: return "Enter a valid SMPTE timecode for the selected frame rate."
        case .invalidDuration: return "This movie does not have a usable duration."
        }
    }
}

/// A lightweight film ruler with frame-based hit markers and scrubbing.
private struct StudioPictureScrubber: View {
    let picture: StudioPictureProject
    let playheadFrame: Int64
    let seek: (Int64) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let denominator = max(1, picture.totalFrames - 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
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
