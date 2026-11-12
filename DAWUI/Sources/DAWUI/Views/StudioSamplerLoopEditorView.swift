import SwiftUI
import AVFoundation
import DAWCore

/// Frame-accurate, nondestructive sustain-loop editing for a sampled zone.
/// Changes only mutate the mapping draft. The actual audio engine receives
/// immutable loop markers after Apply Mapping reloads the sampler snapshot.
public struct StudioSamplerLoopEditorView: View {
    @Binding public var zone: StudioSamplerZone
    @State private var sourceFrames = 0
    @State private var sourceRate = 0.0
    @State private var metadataError: String?

    public init(zone: Binding<StudioSamplerZone>) {
        self._zone = zone
    }

    private enum Marker { case start, end, crossfade }

    private var loopEnabled: Binding<Bool> {
        Binding(
            get: { zone.hasSustainLoop },
            set: { enabled in
                var edited = zone
                if enabled && sourceFrames >= 8 {
                    let start = UInt32(sourceFrames / 4)
                    let end = UInt32(max(Int(start) + 4, sourceFrames * 3 / 4))
                    edited.loopStartFrame = start
                    edited.loopEndFrame = end
                    edited.loopCrossfadeFrames = min(128, (end - start) / 4)
                } else {
                    edited.loopStartFrame = nil
                    edited.loopEndFrame = nil
                    edited.loopCrossfadeFrames = nil
                }
                zone = edited
            }
        )
    }

    private func markerBinding(_ marker: Marker) -> Binding<Int> {
        Binding(
            get: {
                switch marker {
                case .start: return Int(zone.loopStartFrame ?? 0)
                case .end: return Int(zone.loopEndFrame ?? 0)
                case .crossfade: return Int(zone.loopCrossfadeFrames ?? 0)
                }
            },
            set: { newValue in
                guard sourceFrames >= 8, zone.hasSustainLoop else { return }
                var edited = zone
                let start = Int(edited.loopStartFrame ?? 0)
                let end = Int(edited.loopEndFrame ?? 4)
                switch marker {
                case .start:
                    edited.loopStartFrame = UInt32(max(0, min(newValue, end - 4)))
                case .end:
                    edited.loopEndFrame = UInt32(max(start + 4,
                                                        min(sourceFrames, newValue)))
                case .crossfade:
                    edited.loopCrossfadeFrames = UInt32(max(0, newValue))
                }
                let length = Int(edited.loopEndFrame ?? 0) -
                             Int(edited.loopStartFrame ?? 0)
                edited.loopCrossfadeFrames = min(edited.loopCrossfadeFrames ?? 0,
                                                  UInt32(max(0, length / 2)))
                zone = edited
            }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Sustain Loop", systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if sourceRate > 0 {
                    Text("\(sourceFrames) frames · \(String(format: "%.2f", Double(sourceFrames) / sourceRate)) s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Enabled", isOn: loopEnabled)
                    .toggleStyle(.switch)
                    .disabled(sourceFrames < 8)
            }
            if let metadataError {
                Text(metadataError)
                    .font(.caption).foregroundStyle(.orange)
            } else if sourceFrames == 0 {
                ProgressView("Reading sample duration…").controlSize(.small)
            } else if zone.hasSustainLoop {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let first = CGFloat(zone.loopStartFrame ?? 0) / CGFloat(sourceFrames)
                    let last = CGFloat(zone.loopEndFrame ?? 0) / CGFloat(sourceFrames)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.1))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.purple.opacity(0.55))
                            .frame(width: max(0, width * (last - first)))
                            .offset(x: width * first)
                    }
                }
                .frame(height: 18)

                HStack(spacing: 18) {
                    Stepper(
                        "Start: \(zone.loopStartFrame ?? 0)",
                        value: markerBinding(.start),
                        in: 0...max(0, Int(zone.loopEndFrame ?? 4) - 4)
                    )
                    Stepper(
                        "End: \(zone.loopEndFrame ?? 0)",
                        value: markerBinding(.end),
                        in: min(sourceFrames, Int(zone.loopStartFrame ?? 0) + 4)...sourceFrames
                    )
                    Stepper(
                        "Crossfade: \(zone.loopCrossfadeFrames ?? 0)",
                        value: markerBinding(.crossfade),
                        in: 0...max(0,
                            (Int(zone.loopEndFrame ?? 0) -
                             Int(zone.loopStartFrame ?? 0)) / 2)
                    )
                }
                .font(.caption)
                Text("Frames are relative to the source recording. The loop repeats while held; note-off releases through the remainder of the sample. Crossfade blends the loop boundary.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Enable to repeat a section of the recording during sustained notes. The original audio file is never modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: zone.filePath) {
            sourceFrames = 0
            sourceRate = 0
            metadataError = nil
            let url = zone.sampleURL
            let metadata = await Task.detached(priority: .utility) { () -> (Int, Double)? in
                guard let file = try? AVAudioFile(forReading: url) else { return nil }
                return (Int(file.length), file.processingFormat.sampleRate)
            }.value
            if let metadata, metadata.0 >= 8, metadata.0 <= 10_000_000 {
                sourceFrames = metadata.0
                sourceRate = metadata.1
            } else {
                metadataError = "Sample metadata unavailable, or recording too short for a sustain loop."
            }
        }
    }
}
