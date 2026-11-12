import SwiftUI
import DAWCore

/// Nondestructive waveform editor for one sampler zone. All marker edits
/// remain in the mapping draft until the user presses Apply Mapping.
/// Waveform peaks are built in bounded blocks off the main/render threads.
public struct StudioSamplerLoopEditorView: View {
    @Binding public var zone: StudioSamplerZone

    @State private var waveform: StudioSamplerWaveformData?
    @State private var readError: String?
    @State private var zoom = 1.0
    @State private var pan = 0.0
    @State private var selectedMarker: Marker = .trimStart
    @State private var draggingMarker: Marker?

    public init(zone: Binding<StudioSamplerZone>) { self._zone = zone }

    private enum Marker: String, CaseIterable, Identifiable {
        case trimStart = "Sample Start"
        case trimEnd = "Sample End"
        case loopStart = "Loop Start"
        case loopEnd = "Loop End"
        case crossfade = "Crossfade Start"

        var id: String { rawValue }

        var shortLabel: String {
            switch self {
            case .trimStart: return "S"
            case .trimEnd: return "E"
            case .loopStart: return "L"
            case .loopEnd: return "R"
            case .crossfade: return "X"
            }
        }

        var tint: Color {
            switch self {
            case .trimStart, .trimEnd: return .green
            case .loopStart, .loopEnd: return .purple
            case .crossfade: return .orange
            }
        }
    }

    private struct MarkerPosition: Identifiable {
        let marker: Marker
        let frame: Int
        var id: Marker { marker }
    }

    private var frames: Int { waveform?.totalFrames ?? 0 }
    private var rate: Double { waveform?.sampleRate ?? 1 }
    private var trimStart: Int { Int(zone.trimStartFrame ?? 0) }
    private var trimEnd: Int { Int(zone.trimEndFrame ?? UInt32(frames)) }

    private var markerPositions: [MarkerPosition] {
        var markers = [
            MarkerPosition(marker: .trimStart, frame: trimStart),
            MarkerPosition(marker: .trimEnd, frame: trimEnd)
        ]
        if let a = zone.loopStartFrame, let b = zone.loopEndFrame {
            markers.append(MarkerPosition(marker: .loopStart, frame: Int(a)))
            markers.append(MarkerPosition(marker: .loopEnd, frame: Int(b)))
            if let fade = zone.loopCrossfadeFrames, fade > 0 {
                markers.append(MarkerPosition(marker: .crossfade,
                                              frame: Int(b - fade)))
            }
        }
        return markers
    }

    private var visibleRange: (start: Double, length: Double) {
        let count = Double(max(1, frames))
        let length = count / zoom
        return (pan * (count - length), length)
    }

    private var loopEnabled: Binding<Bool> {
        Binding(
            get: { zone.hasSustainLoop },
            set: { enabled in
                var updated = zone
                if enabled && trimEnd - trimStart >= 8 {
                    let a = trimStart + (trimEnd - trimStart) / 4
                    let b = trimStart + 3 * (trimEnd - trimStart) / 4
                    updated.loopStartFrame = UInt32(a)
                    updated.loopEndFrame = UInt32(b)
                    updated.loopCrossfadeFrames = UInt32(min(128, (b - a) / 4))
                } else {
                    updated.loopStartFrame = nil
                    updated.loopEndFrame = nil
                    updated.loopCrossfadeFrames = nil
                }
                zone = updated
            }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Waveform & Loop Editor", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let waveform {
                    Text(String(format: "%.2f sec · %.0f Hz · %d frames",
                                Double(waveform.totalFrames) / waveform.sampleRate,
                                waveform.sampleRate, waveform.totalFrames))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Sustain Loop", isOn: loopEnabled)
                    .toggleStyle(.switch)
                    .disabled(frames < 8 || trimEnd - trimStart < 8)
            }

            if let waveform {
                waveformViewport(waveform)
                HStack(spacing: 12) {
                    Picker("Drag marker", selection: $selectedMarker) {
                        ForEach(Marker.allCases) { marker in
                            Text(marker.rawValue).tag(marker)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)
                    HStack(spacing: 5) {
                        Image(systemName: "plus.magnifyingglass")
                        Slider(value: $zoom, in: 1...16)
                            .frame(width: 130)
                        Text(String(format: "%.1fx", zoom))
                            .font(.caption.monospacedDigit())
                    }
                    Spacer()
                    Text("Scroll position")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $pan, in: 0...1)
                        .frame(width: 145)
                        .disabled(zoom <= 1.01)
                    Button("Fit") {
                        zoom = 1
                        pan = 0
                    }
                }
                .font(.caption)
                HStack(spacing: 22) {
                    markerStepper(.trimStart, label: "Sample Start")
                    markerStepper(.trimEnd, label: "Sample End")
                    if zone.hasSustainLoop {
                        markerStepper(.loopStart, label: "Loop Start")
                        markerStepper(.loopEnd, label: "Loop End")
                        markerStepper(.crossfade, label: "Crossfade")
                    }
                }
                .font(.caption)
                Text("Drag a marker handle (S/E/L/R/X) or choose a marker and drag in the waveform. The shaded section is the audible sample region. Original audio is never changed; Apply Mapping commits edits to playback.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let readError {
                Label(readError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ProgressView("Analyzing sample waveform…")
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: zone.filePath) {
            waveform = nil
            readError = nil
            zoom = 1
            pan = 0
            let url = zone.sampleURL
            do {
                let result = try await Task.detached(priority: .utility) {
                    try StudioSamplerWaveformAnalyzer.analyze(url: url)
                }.value
                if !Task.isCancelled { waveform = result }
            } catch {
                if !Task.isCancelled { readError = error.localizedDescription }
            }
        }
    }

    private func markerStepper(_ marker: Marker, label: String) -> some View {
        let value = markerPositions.first(where: { $0.marker == marker })?.frame ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Stepper("\(value)", value: Binding(
                get: { markerPositions.first(where: { $0.marker == marker })?.frame ?? 0 },
                set: { editMarker(marker, frame: $0) }
            ), in: 0...max(0, frames))
            .frame(minWidth: 95)
        }
    }

    private func waveformViewport(_ peaks: StudioSamplerWaveformData) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let height = geometry.size.height
            let range = visibleRange
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.55))
                StudioSamplerWaveformPlot(
                    waveform: peaks, visibleStart: range.start,
                    visibleLength: range.length
                )
                .padding(.vertical, 9)

                trimShade(width: width, height: height, start: range.start,
                          length: range.length)
                if zone.hasSustainLoop {
                    let a = normalizedX(Int(zone.loopStartFrame ?? 0), width: width,
                                        start: range.start, length: range.length)
                    let b = normalizedX(Int(zone.loopEndFrame ?? 0), width: width,
                                        start: range.start, length: range.length)
                    if b >= 0 && a <= width {
                        Rectangle()
                            .fill(Color.purple.opacity(0.13))
                            .frame(width: max(0, min(width, b) - max(0, a)),
                                   height: height)
                            .offset(x: max(0, a))
                    }
                }
                ForEach(markerPositions) { entry in
                    let x = normalizedX(entry.frame, width: width,
                                        start: range.start, length: range.length)
                    if x >= 0 && x <= width {
                        Rectangle()
                            .fill(entry.marker.tint)
                            .frame(width: 2, height: height)
                            .offset(x: x)
                        Text(entry.marker.shortLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(entry.marker.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .offset(x: max(0, min(width - 25, x - 11)), y: 3)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = drag.location.x
                        if draggingMarker == nil {
                            let nearest = markerPositions
                                .map { ($0.marker,
                                        abs(normalizedX($0.frame, width: width,
                                                start: range.start,
                                                length: range.length) - x)) }
                                .min { $0.1 < $1.1 }
                            draggingMarker = (nearest?.1 ?? 1000) <= 17
                                ? nearest?.0 : selectedMarker
                        }
                        let newFrame = Int((range.start +
                            Double(max(0, min(width, x)) / width) *
                            range.length).rounded())
                        editMarker(draggingMarker ?? selectedMarker, frame: newFrame)
                    }
                    .onEnded { _ in draggingMarker = nil }
            )
        }
        .frame(height: 225)
    }

    private func trimShade(width: CGFloat, height: CGFloat,
                           start: Double, length: Double) -> some View {
        let a = normalizedX(trimStart, width: width, start: start, length: length)
        let b = normalizedX(trimEnd, width: width, start: start, length: length)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.40))
                .frame(width: max(0, min(width, a)), height: height)
            Rectangle()
                .fill(Color.black.opacity(0.40))
                .frame(width: max(0, width - max(0, min(width, b))),
                       height: height)
                .offset(x: max(0, min(width, b)))
        }
    }

    private func normalizedX(_ frame: Int, width: CGFloat,
                             start: Double, length: Double) -> CGFloat {
        CGFloat((Double(frame) - start) / max(1, length)) * width
    }

    private func editMarker(_ marker: Marker, frame: Int) {
        guard frames >= 2 else { return }
        let position = max(0, min(frames, frame))
        var updated = zone
        switch marker {
        case .trimStart:
            let maximum = zone.hasSustainLoop
                ? Int(zone.loopStartFrame ?? 0) : trimEnd - 2
            let value = max(0, min(position, maximum, trimEnd - 2))
            updated.trimStartFrame = value == 0 ? nil : UInt32(value)
        case .trimEnd:
            let minimum = zone.hasSustainLoop
                ? Int(zone.loopEndFrame ?? 0) : trimStart + 2
            let value = max(minimum, min(frames, position))
            updated.trimEndFrame = value == frames ? nil : UInt32(value)
        case .loopStart:
            guard let end = zone.loopEndFrame else { return }
            let value = max(trimStart, min(position, Int(end) - 4))
            updated.loopStartFrame = UInt32(value)
        case .loopEnd:
            guard let start = zone.loopStartFrame else { return }
            let value = max(Int(start) + 4, min(trimEnd, position))
            updated.loopEndFrame = UInt32(value)
        case .crossfade:
            guard let end = zone.loopEndFrame, let start = zone.loopStartFrame else {
                return
            }
            let fade = max(0, min(Int(end) - position, Int(end - start) / 2))
            updated.loopCrossfadeFrames = UInt32(fade)
        }
        if let a = updated.loopStartFrame, let b = updated.loopEndFrame {
            updated.loopCrossfadeFrames =
                min(updated.loopCrossfadeFrames ?? 0, (b - a) / 2)
        }
        if updated.isValid { zone = updated }
    }
}

/// Draw at most one waveform line per visible screen pixel, no audio decoding,
/// allocations of sample buffers or work on the audio rendering callback.
private struct StudioSamplerWaveformPlot: View {
    let waveform: StudioSamplerWaveformData
    let visibleStart: Double
    let visibleLength: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, !waveform.peaks.isEmpty else {
                return
            }
            let lines = min(1200, max(1, Int(size.width)))
            var path = Path()
            let center = size.height / 2
            for column in 0..<lines {
                let frame = visibleStart +
                    Double(column) / Double(lines) * visibleLength
                let bucket = min(waveform.peaks.count - 1, max(0,
                    Int(frame / Double(waveform.totalFrames) *
                        Double(waveform.peaks.count))))
                let amplitude = CGFloat(min(1, waveform.peaks[bucket]))
                let halfHeight = amplitude * size.height * 0.47
                let x = CGFloat(column) * size.width / CGFloat(lines)
                path.move(to: CGPoint(x: x, y: center - halfHeight))
                path.addLine(to: CGPoint(x: x, y: center + halfHeight))
            }
            context.stroke(path, with: .color(.purple.opacity(0.92)),
                           lineWidth: max(1, size.width / CGFloat(lines)))
        }
        .accessibilityLabel("Sample waveform with zoomable source-frame markers")
    }
}
