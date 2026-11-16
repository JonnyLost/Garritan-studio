import AVFoundation
import Combine
import DAWCore
import Foundation

/// Single-action film delivery using the *existing* Studio stereo mix engine.
/// Stage the WAV in the destination folder, use native movie export, then
/// erase only this operation's scratch directory. No second audio renderer.
@MainActor
final class StudioPictureOneStepExport: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""

    private let audioExporter = StudioExportCoordinator()
    private let movieExporter = StudioPictureMovieExporter()
    private var progressSubscriptions: [AnyCancellable] = []

    enum WorkflowError: LocalizedError {
        case busy, pictureChanged, noStereoMix, outputExists, insufficientDuration

        var errorDescription: String? {
            switch self {
            case .busy: return "A scored-movie delivery is already in progress."
            case .pictureChanged: return "The picture or project changed during delivery. Export canceled."
            case .noStereoMix: return "Studio did not produce the requested stereo mix."
            case .outputExists: return "The destination already exists. Choose a new movie filename."
            case .insufficientDuration:
                return "The project ends before the movie begins. Extend the score arrangement first."
            }
        }
    }

    func export(projectViewModel viewModel: ProjectViewModel,
                picture: StudioPictureProject,
                destination: URL,
                includeReferenceAudio: Bool,
                referenceGain: Float,
                format: StudioPictureDeliveryFormat,
                burnInTimecode: Bool,
                tailSeconds: Double = 3,
                bitDepth: Int = 24) async throws {
        guard !isExporting else { throw WorkflowError.busy }
        try Self.validateDestination(
            destination, sourceMoviePath: picture.filePath, format: format)
        let project = viewModel.project
        guard project.studioPicture == picture else { throw WorkflowError.pictureChanged }
        let renderDuration = try StudioExportPlan.renderSeconds(
            project: project, tailSeconds: tailSeconds)
        guard renderDuration > picture.timelineStartSeconds else {
            throw WorkflowError.insufficientDuration
        }
        // Preflight the existing mix pass before any render changes transport.
        let settings = StudioExportSettings(
            mode: .stereoMix, tailSeconds: tailSeconds, bitDepth: bitDepth)
        _ = try StudioExportPlan.makePasses(project: project, settings: settings)

        isExporting = true
        progress = 0
        status = "Preparing Studio stereo mix…"
        defer {
            progressSubscriptions.removeAll()
            isExporting = false
        }

        // A unique hidden folder is the only scratch footprint. Even on
        // cancellation/error, the directory and internal WAV are removed.
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent(".studio-scored-delivery-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }

        audioExporter.$progress.sink { [weak self] value in
            self?.progress = min(0.8, max(0, value) * 0.8)
        }.store(in: &progressSubscriptions)
        audioExporter.$status.sink { [weak self] message in
            self?.status = "Rendering Studio mix: " + message
        }.store(in: &progressSubscriptions)

        let files = try await audioExporter.export(
            projectViewModel: viewModel, settings: settings, to: scratch)
        try Task.checkCancellation()
        guard let mix = files.first, files.count == 1,
              mix.pathExtension.lowercased() == "wav" else {
            throw WorkflowError.noStereoMix
        }
        // Reject changed project/media after a long render instead of
        // combining an old audio take with a new picture or cue mapping.
        guard viewModel.project.studioPicture == picture else {
            throw WorkflowError.pictureChanged
        }

        progressSubscriptions.removeAll()
        movieExporter.$progress.sink { [weak self] value in
            self?.progress = 0.8 + min(1, max(0, value)) * 0.2
        }.store(in: &progressSubscriptions)
        movieExporter.$status.sink { [weak self] message in
            self?.status = "Delivering scored movie: " + message
        }.store(in: &progressSubscriptions)
        status = "Combining Studio mix with picture…"
        try await movieExporter.export(
            picture: picture, scoreURL: mix,
            destination: destination,
            includeReferenceAudio: includeReferenceAudio,
            referenceGain: referenceGain,
            format: format,
            burnInTimecode: burnInTimecode)
        // MovieExporter commits only after successful encoding and its own
        // cancellation check. Do not report a completed deliverable as canceled
        // if the user presses Cancel after the final file has been committed.
        progress = 1
        status = "Scored movie ready"
    }

    static func validateDestination(
        _ destination: URL,
        sourceMoviePath: String,
        format: StudioPictureDeliveryFormat
    ) throws {
        guard destination.pathExtension.lowercased() == format.fileExtension,
              destination.standardizedFileURL !=
                URL(fileURLWithPath: sourceMoviePath).standardizedFileURL else {
            throw StudioPictureMovieExportError.destinationConflictsWithSource
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkflowError.outputExists
        }
    }

    func cancel() {
        movieExporter.cancel()
        // StudioExportCoordinator observes cancellation on its running Task.
        // The caller cancels that task; no transport stop is needed here.
    }
}
