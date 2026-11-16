import AppKit
import AVFoundation
import DAWCore
import SwiftUI
import UniformTypeIdentifiers

/// Directors frequently send a new edit of the same scene. This review sheet
/// never guesses which frames match: the composer supplies matching moments,
/// examines a per-cue preview, and explicitly approves cue remapping.
struct StudioPictureRevisionView: View {
    @Environment(\.dismiss) private var dismiss
    let original: StudioPictureProject
    let apply: (StudioPictureProject) -> Void

    @State private var replacement: StudioPictureProject?
    @State private var anchors: [StudioPictureRevisionAnchor] = [
        StudioPictureRevisionAnchor(oldFrame: 0, newFrame: 0)
    ]
    @State private var preview: StudioPictureRevisionPreview?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Conform Picture Revision", systemImage: "film.stack")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Text("Replace the picture after an edit changes, keeping cue IDs, notes and Studio's music intact. Enter moments that represent the same shot or event in both versions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current: \(original.filename)")
                        .font(.caption.weight(.medium))
                    Text("\(original.totalFrames) frames • \(original.frameRate.displayName) fps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Choose Revised Movie…") { chooseMovie() }
                    .disabled(isLoading)
            }
            if let replacement {
                Text("New: \(replacement.filename) • \(replacement.totalFrames) frames • \(replacement.frameRate.displayName) fps")
                    .font(.caption)
            }

            Divider()

            HStack {
                Text("Match points").font(.headline)
                Spacer()
                Button {
                    anchors.append(StudioPictureRevisionAnchor(oldFrame: 0,
                                                               newFrame: 0))
                } label: {
                    Label("Add Match Point", systemImage: "plus")
                }
                .disabled(replacement == nil)
            }
            Text("Use picture-relative frame numbers. For cuts or inserted footage, add another match point immediately after each edit. Match points must increase in both films.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("Original frame").frame(maxWidth: .infinity, alignment: .leading)
                Text("Revised frame").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 24)
            }
            .font(.caption.weight(.medium))
            ForEach($anchors) { $anchor in
                HStack(spacing: 12) {
                    TextField("Original frame", value: $anchor.oldFrame,
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                    TextField("Revised frame", value: $anchor.newFrame,
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        anchors.removeAll(where: { $0.id == anchor.id })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(anchors.count == 1)
                }
            }
            .onChange(of: anchors) { _, _ in
                preview = nil
                errorMessage = nil
            }

            HStack {
                Button("Preview Cue Changes") { calculatePreview() }
                    .disabled(replacement == nil || isLoading)
                Spacer()
                if let preview {
                    Text("\(preview.movedCount) moved • \(preview.unresolvedCount) unresolved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(preview.unresolvedCount == 0 ? Color.secondary : Color.orange)
                }
            }

            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(preview.changes) { change in
                            HStack(spacing: 8) {
                                Text(change.name)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(change.previousTimecode)
                                    .font(.system(.caption, design: .monospaced))
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                Text(change.proposedTimecode ?? "Outside movie")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(change.proposedFrame == nil ? Color.orange : Color.primary)
                            }
                            .font(.caption)
                        }
                        if preview.changes.isEmpty {
                            Text("No saved hit points need remapping.")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 85, maxHeight: 160)
            } else {
                Text("Preview before applying. Existing cues and music remain unchanged until you approve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Text("This operation moves picture hit points only. MIDI, audio clips, tempo and automation are not conformed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Apply Revised Picture") { applyRevision() }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview == nil || preview?.unresolvedCount != 0 ||
                              replacement == nil || isLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 530)
    }

    private func chooseMovie() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Director's Revised Picture"
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        preview = nil
        replacement = nil
        errorMessage = nil
        isLoading = true
        let access = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                isLoading = false
            }
            do {
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable),
                      let track = try await asset.loadTracks(withMediaType: .video).first
                else { throw StudioPictureRevisionImportError.invalidMovie }
                let duration = try await asset.load(.duration).seconds
                let fps = Double((try? await track.load(.nominalFrameRate)) ?? 24)
                guard duration.isFinite, duration > 0,
                      fps.isFinite, fps > 0 else {
                    throw StudioPictureRevisionImportError.invalidMovie
                }
                let bookmark = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                replacement = StudioPictureProject(
                    url: url, durationSeconds: duration,
                    frameRate: StudioPictureFrameRate.closest(to: fps),
                    securityBookmark: bookmark)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func calculatePreview() {
        guard let replacement else { return }
        do {
            preview = try StudioPictureRevisionConformer.preview(
                old: original, replacement: replacement, anchors: anchors)
            errorMessage = preview?.unresolvedCount == 0 ? nil :
                "Some hit points fall outside the revised footage. Adjust match points before applying."
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func applyRevision() {
        guard let replacement, let preview else { return }
        do {
            let conformed = try StudioPictureRevisionConformer.conform(
                old: original, replacement: replacement, preview: preview)
            apply(conformed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum StudioPictureRevisionImportError: LocalizedError {
    case invalidMovie

    var errorDescription: String? {
        "The revised file has no usable movie video track or duration."
    }
}
