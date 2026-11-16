import AppKit
import DAWCore
import SwiftUI
import UniformTypeIdentifiers

/// Final picture delivery: select an already-bounced Studio Stereo Mix WAV,
/// combine it with the referenced movie, optionally retain production sound.
struct StudioPictureMovieExportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = StudioPictureMovieExporter()
    @State private var scoreURL: URL?
    @State private var includeDialogue = true
    @State private var dialogueGain: Double
    @State private var deliveryFormat: StudioPictureDeliveryFormat = .quickTime
    @State private var burnInTimecode = false
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var exportTask: Task<Void, Never>?

    private let picture: StudioPictureProject

    init(picture: StudioPictureProject) {
        self.picture = picture
        _dialogueGain = State(initialValue: Double(picture.referenceAudioVolume ?? 0.65))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export Scored Movie")
                        .font(.headline)
                    Text("Combine your Studio Stereo Mix with the original picture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Render a Stereo Mix")
                    .font(.subheadline.weight(.semibold))
                Text("First export your music as a Stereo Mix WAV using File → Export Audio & Stems. Then choose that WAV here. Your original movie is never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button {
                        chooseScore()
                    } label: {
                        Label("Choose Studio Mix WAV…", systemImage: "waveform")
                    }
                    Text(scoreURL?.lastPathComponent ?? "No mix selected")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("2. Choose movie audio")
                    .font(.subheadline.weight(.semibold))
                Toggle("Include original dialogue and production audio",
                       isOn: $includeDialogue)
                HStack {
                    Text("Production sound volume")
                        .font(.caption)
                    Slider(value: $dialogueGain, in: 0...1)
                        .disabled(!includeDialogue)
                    Text(String(format: "%.0f%%", dialogueGain * 100))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 46)
                }
                Text("Studio's music mix stays at its exported level. Picture audio is an optional separate layer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("3. Choose delivery format")
                    .font(.subheadline.weight(.semibold))
                Picker("Video format", selection: $deliveryFormat) {
                    ForEach(StudioPictureDeliveryFormat.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Burn SMPTE timecode into exported video",
                       isOn: $burnInTimecode)
                Text("Burn-in is permanent on the delivered movie only. The saved source picture is unchanged. Turning it on adds offline video processing time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Studio aligns the music to the movie using the saved picture offset (\(String(format: "%.2f", picture.timelineStartSeconds)) seconds). The export is limited to the movie duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if exporter.isExporting {
                    ProgressView(value: exporter.progress)
                    Text(exporter.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let exportedURL {
                    Label("Export complete: \(exportedURL.lastPathComponent)",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Button("Close") { dismiss() }
                    .disabled(exporter.isExporting)
                Spacer()
                if exporter.isExporting {
                    Button("Cancel Export") {
                        exportTask?.cancel()
                        exporter.cancel()
                    }
                }
                Button("Export Scored Movie…") { chooseDestinationAndExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(exporter.isExporting || scoreURL == nil)
            }
        }
        .padding(20)
        .frame(width: 570, height: 510)
        .onDisappear {
            exportTask?.cancel()
            exporter.cancel()
        }
    }

    private func chooseScore() {
        let panel = NSOpenPanel()
        panel.title = "Choose your rendered Studio Stereo Mix"
        panel.allowedContentTypes = [.wav]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { scoreURL = panel.url }
    }

    private func chooseDestinationAndExport() {
        guard let scoreURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save Scored Movie"
        panel.allowedContentTypes = deliveryFormat == .mp4
            ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.nameFieldStringValue =
            ((picture.filename as NSString).deletingPathExtension) +
            "-Scored." + deliveryFormat.fileExtension
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        errorMessage = nil
        exportedURL = nil

        exportTask = Task {
            defer { exportTask = nil }
            do {
                try await exporter.export(
                    picture: picture,
                    scoreURL: scoreURL,
                    destination: destination,
                    includeReferenceAudio: includeDialogue,
                    referenceGain: Float(dialogueGain),
                    format: deliveryFormat,
                    burnInTimecode: burnInTimecode)
                exportedURL = destination
            } catch is CancellationError {
                errorMessage = "Movie export canceled. No source movie or audio was modified."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
