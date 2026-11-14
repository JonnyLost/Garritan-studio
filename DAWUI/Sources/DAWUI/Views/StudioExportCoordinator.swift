import Foundation
import AVFoundation
import DAWCore

/// Deliberate real-time bounce using Studio's *existing* AVAudioEngine signal
/// chain. Offline AU rendering and faster-than-real-time DSP are separate
/// future milestones: this path preserves the audible track inserts, pan,
/// native/hosted instrument output and each selected track's hall send.
@MainActor
public final class StudioExportCoordinator: ObservableObject {
    @Published public private(set) var isExporting = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var status: String = ""
    @Published public private(set) var exportedFiles: [URL] = []

    public enum ExportError: Error, LocalizedError {
        case busy
        case unsupportedBackend
        case sharedRack(TrackID)
        case missingInstrument(String)
        case missingAudio(String)
        case outputExists(URL)
        case captureFailed(String)
        case playbackStopped
        case recordingGap
        case captureUnavailable
        case projectChanged

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "Stop playback or recording before exporting."
            case .unsupportedBackend:
                return "Export currently supports Studio's AVAudioEngine backend, not the experimental Core Audio backend."
            case .sharedRack:
                return "Tracks routed to a shared V-Rack instrument need the V-Rack stem-isolation milestone before they can be exported safely."
            case .missingInstrument(let name):
                return "The instrument on '\(name)' is not loaded. Restore it before exporting."
            case .missingAudio(let name):
                return "A source audio file for '\(name)' cannot be opened."
            case .outputExists(let url):
                return "'\(url.lastPathComponent)' already exists. Choose another folder to protect existing exports."
            case .captureFailed(let detail):
                return "The mixdown was not saved: \(detail)"
            case .playbackStopped:
                return "Playback was interrupted. No incomplete stem files were committed."
            case .recordingGap:
                return "Audio capture was too short to contain the complete render; the partial file was discarded."
            case .captureUnavailable:
                return "Studio could not finish the audio capture."
            case .projectChanged:
                return "The project was modified during export. The staged audio was not committed."
            }
        }
    }

    public init() {}

    /// The destination is an existing folder. All passes render into one
    /// hidden staging folder there and are moved into place only after every
    /// pass, format conversion and capture-integrity check succeeds.
    @discardableResult
    public func export(
        projectViewModel viewModel: ProjectViewModel,
        settings: StudioExportSettings,
        to destinationDirectory: URL
    ) async throws -> [URL] {
        guard !isExporting,
              !viewModel.transportState.isPlaying,
              !viewModel.transportState.isRecording,
              !viewModel.isRecording,
              !viewModel.audioRecorder.isRecording,
              !viewModel.playbackEngine.isRecordingVRack else {
            throw ExportError.busy
        }
        guard viewModel.playbackEngine.supportsStudioMixdown else {
            throw ExportError.unsupportedBackend
        }

        let snapshot = viewModel.project
        let passes = try StudioExportPlan.makePasses(project: snapshot, settings: settings)
        let duration = try StudioExportPlan.renderSeconds(
            project: snapshot, tailSeconds: settings.tailSeconds
        )
        let selected = passes.reduce(into: Set<TrackID>()) { $0.formUnion($1.trackIDs) }
        try preflight(project: snapshot, selected: selected, viewModel: viewModel)

        let fileManager = FileManager.default
        for pass in passes {
            let target = destinationDirectory.appendingPathComponent(pass.fileName)
            guard !fileManager.fileExists(atPath: target.path) else {
                throw ExportError.outputExists(target)
            }
        }

        let staging = destinationDirectory.appendingPathComponent(
            ".studio-export-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let transport = viewModel.transportState
        let engine = viewModel.audioEngine
        let playback = viewModel.playbackEngine
        let originalBeat = transport.playheadBeats
        let originalLoop = transport.isLoopEnabled
        let originalMetronome = transport.isMetronomeEnabled
        let originalRackLevel = playback.muteSharedRackDuringExport()
        let originalMonitoring = viewModel.audioRecorder.inputMonitoringEnabled
        viewModel.audioRecorder.stopInputMonitoring()

        isExporting = true
        viewModel.beginStudioExport()
        exportedFiles = []
        progress = 0
        var captureOpen = false
        defer {
            if transport.isPlaying { transport.stop() }
            if captureOpen { _ = engine.endMixdownCapture() }
            viewModel.endStudioExport()
            engine.updateSoloState(tracks: viewModel.project.tracks)
            playback.restoreSharedRackLevel(originalRackLevel)
            transport.isLoopEnabled = originalLoop
            transport.isMetronomeEnabled = originalMetronome
            engine.setMetronomeEnabled(originalMetronome)
            transport.setPlayheadBeats(originalBeat)
            viewModel.audioRecorder.inputMonitoringEnabled = originalMonitoring
            if originalMonitoring { viewModel.audioRecorder.startInputMonitoring() }
            isExporting = false
        }

        transport.isLoopEnabled = false
        transport.isMetronomeEnabled = false
        engine.setMetronomeEnabled(false)
        let rate = engine.sampleRate
        let targetFrames = Int64((duration * rate).rounded())
        guard rate.isFinite, rate > 0, targetFrames > 0 else {
            throw StudioExportPlan.PlanningError.invalidDuration
        }

        var outputPaths: [URL] = []
        for (index, pass) in passes.enumerated() {
            try Task.checkCancellation()
            guard viewModel.project.modifiedAt == snapshot.modifiedAt else {
                throw ExportError.projectChanged
            }
            status = "Rendering \(pass.name) (\(index + 1) of \(passes.count))"
            progress = Double(index) / Double(passes.count)

            let isolated = StudioExportPlan.isolatedProject(snapshot, for: pass)
            transport.setPlayheadBeats(0)
            playback.resetInstrumentsForExport()
            engine.resetExportHallTail()
            engine.resetExportTrackEffects()
            engine.applyExportIsolation(selected: pass.trackIDs, tracks: snapshot.tracks)
            viewModel.prepareStudioExportPass(isolated)

            let sourceURL = staging.appendingPathComponent("capture-\(index).wav")
            try engine.beginMixdownCapture(to: sourceURL, bitDepth: settings.bitDepth)
            captureOpen = true
            transport.play()

            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                try Task.checkCancellation()
                guard transport.isPlaying else { throw ExportError.playbackStopped }
                let timeRemaining = deadline.timeIntervalSinceNow
                if timeRemaining > 0 {
                    let interval = min(0.1, timeRemaining)
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                let elapsed = max(0, duration - max(0, deadline.timeIntervalSinceNow))
                progress = (Double(index) + min(1, elapsed / duration)) / Double(passes.count)
            }

            transport.stop()
            // Deliver queued .stop before preparing another pass. Never let
            // the previous transport event stop the next pass's instruments.
            await Task.yield()
            guard let capture = engine.endMixdownCapture() else {
                throw ExportError.captureUnavailable
            }
            captureOpen = false
            guard capture.succeeded else {
                throw ExportError.captureFailed(
                    capture.writeError ??
                    "Audio writer overflowed by \(capture.droppedFrames) frames"
                )
            }
            guard capture.writtenFrames >= targetFrames - Int64(rate * 0.25) else {
                throw ExportError.recordingGap
            }
            let stagedOutput = staging.appendingPathComponent("output-\(index).wav")
            status = "Finalizing \(pass.name)"
            try await Task.detached(priority: .userInitiated) {
                try StudioExportPCMWriter.convert(
                    source: sourceURL, destination: stagedOutput,
                    channels: pass.channelCount, bitDepth: settings.bitDepth,
                    targetFrames: targetFrames
                )
            }.value
            try? fileManager.removeItem(at: sourceURL)
            outputPaths.append(stagedOutput)
        }

        // Complete all staged files before touching the selected destination.
        // On any move error, delete only files inserted by THIS export; never
        // overwrite or delete somebody else's existing file.
        guard viewModel.project.modifiedAt == snapshot.modifiedAt else {
            throw ExportError.projectChanged
        }
        var committed: [URL] = []
        do {
            for (index, pass) in passes.enumerated() {
                let finalURL = destinationDirectory.appendingPathComponent(pass.fileName)
                guard !fileManager.fileExists(atPath: finalURL.path) else {
                    throw ExportError.outputExists(finalURL)
                }
                try fileManager.moveItem(at: outputPaths[index], to: finalURL)
                committed.append(finalURL)
            }
        } catch {
            for url in committed { try? fileManager.removeItem(at: url) }
            throw error
        }
        progress = 1
        status = "Export complete"
        exportedFiles = committed
        return committed
    }

    private func preflight(
        project: Project, selected: Set<TrackID>,
        viewModel: ProjectViewModel
    ) throws {
        for track in project.tracks where selected.contains(track.id) {
            if case .rackInstrument = track.midiOutput {
                throw ExportError.sharedRack(track.id)
            }
            for clip in track.clips where !clip.isMuted {
                switch clip.content {
                case .midi(let data):
                    guard data.events.isEmpty ||
                          viewModel.playbackEngine.instrument(for: track.id) != nil else {
                        throw ExportError.missingInstrument(track.name)
                    }
                case .audio(let data):
                    guard FileManager.default.fileExists(
                        atPath: data.fileReference.originalPath
                    ) else {
                        throw ExportError.missingAudio(track.name)
                    }
                case .empty: break
                }
            }
        }
    }
}

/// Streaming PCM conversion, off the main actor. This final stage gives every
/// stem an exact common frame count and an actual mono or stereo WAV header.
/// Source buffers are bounded; a whole orchestral session is never read into RAM.
enum StudioExportPCMWriter {
    static func convert(
        source: URL, destination: URL,
        channels: Int, bitDepth: Int, targetFrames: Int64
    ) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.channelCount == 2,
              format.commonFormat == .pcmFormatFloat32,
              (channels == 1 || channels == 2),
              (bitDepth == 16 || bitDepth == 24),
              targetFrames > 0,
              let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: AVAudioChannelCount(channels)
              ),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: 4096
              ),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: 4096
              ) else {
            throw StudioExportCoordinator.ExportError.captureFailed(
                "Unsupported mixdown PCM format"
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )

        var remaining = targetFrames
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, 4096))
            inputBuffer.frameLength = 0
            try input.read(into: inputBuffer, frameCount: frames)
            let captured = Int(inputBuffer.frameLength)
            let needed = Int(frames)
            outputBuffer.frameLength = frames
            guard let inData = inputBuffer.floatChannelData,
                  let outData = outputBuffer.floatChannelData else {
                throw StudioExportCoordinator.ExportError.captureFailed(
                    "Unable to access export sample buffers"
                )
            }
            for i in 0..<needed {
                let l = i < captured ? inData[0][i] : 0
                let r = i < captured ? inData[1][i] : 0
                outData[0][i] = channels == 1 ? 0.5 * (l + r) : l
                if channels == 2 { outData[1][i] = r }
            }
            try file.write(from: outputBuffer)
            remaining -= Int64(frames)
        }
    }
}
