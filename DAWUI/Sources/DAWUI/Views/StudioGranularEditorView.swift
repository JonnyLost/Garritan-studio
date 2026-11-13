import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import DAWCore

/// The first source implementation uses private, bounded in-memory PCM.
/// The sampler's future shared source manager can replace this isolated
/// import helper without changing granular patches or DSP parameters.
private enum StudioGranularSourceImporter {
    static func copyIntoLocalLibrary(_ url: URL) throws -> URL {
        let scoped=url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let manager=FileManager.default
        let attrs=try manager.attributesOfItem(atPath:url.path)
        let bytes=(attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 && bytes <= 64*1024*1024 else {
            throw StudioGranularError.cannotReadSource(
                "Choose an audio file smaller than 64 MB for this first engine.")
        }
        // Reject non-audio files before copying into Studio's local library.
        _ = try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,
                            interleaved:false)
        let root=try manager.url(for:.applicationSupportDirectory,
                                 in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("Garritan Studio",isDirectory:true)
            .appendingPathComponent("Granular Sources",isDirectory:true)
        try manager.createDirectory(at:root,withIntermediateDirectories:true)
        let ext=url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let target=root.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try manager.copyItem(at:url,to:target)
        return target
    }
}

/// Native grain-cloud editor within the unified Studio Synth surface.
/// Grain parameters update DSP atomics; source swaps reconstruct the layer
/// outside the audio render callback through the existing patch-update path.
struct StudioGranularEditorView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let layerID: UUID
    let onChangeSource: (StudioGranularPatch) -> Void
    @State private var importPresented=false
    @State private var importError: String?

    private var sound: StudioGranularPatch {
        viewModel.project.track(withID:trackID)?.studioSynthPatch?
            .layers.first(where:{$0.id==layerID})?.granularPatch ??
            StudioGranularPatch()
    }
    private func slider(_ parameter: StudioGranularParameter) -> some View {
        HStack(spacing:8) {
            Text(parameter.name)
                .font(.caption)
                .frame(width:112,alignment:.leading)
            Slider(value:Binding<Double>(
                get: {parameter.position(for:sound.value(for:parameter))},
                set: { value in
                    viewModel.setStudioSynthGranularParameter(
                        parameter,value:parameter.value(at:value),
                        for:trackID,layerID:layerID)
                }),in:0...1).tint(.purple)
            Text(parameter.displayValue(sound.value(for:parameter)))
                .font(.caption.monospacedDigit())
                .frame(width:79,alignment:.trailing)
        }
        .contextMenu {
            Button("Learn MIDI CC") {
                _ = viewModel.beginStudioSynthMIDILearn(
                    for:trackID,
                    target:.parameter(layerID:layerID,
                                      destination:.granular(parameter)))
            }
        }
    }
    private func sliders(_ params:[StudioGranularParameter]) -> some View {
        LazyVGrid(columns:[GridItem(.flexible(minimum:260)),
                           GridItem(.flexible(minimum:260))],spacing:12) {
            ForEach(params,id:\.rawValue) { param in slider(param) }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:15) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("GRAIN CLOUD")
                        .font(.caption.weight(.bold)).foregroundStyle(.purple)
                    Text("Sample fragments · independent stereo grains · native polyphony")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("MAX 8 VOICES")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing:12) {
                Picker("Source",selection:Binding<StudioGranularSource>(
                    get:{sound.source},
                    set:{source in
                        var updated=sound
                        updated.source=source
                        updated.importedAudioPath=nil
                        onChangeSource(updated)
                    })) {
                    ForEach(StudioGranularSource.allCases) { source in
                        Text(source.name).tag(source)
                    }
                }
                .disabled(sound.importedAudioPath != nil)
                Button {
                    importPresented=true
                } label: {
                    Label("Import Audio",systemImage:"square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                if sound.importedAudioPath != nil {
                    Button("Use Factory Source") {
                        var updated=sound
                        updated.importedAudioPath=nil
                        onChangeSource(updated)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let path=sound.importedAudioPath {
                Text("Imported: \(URL(fileURLWithPath:path).lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("Factory sources are generated inside Studio. Imported audio is decoded once when the instrument loads, up to 524,288 frames; there is no file reading in the audio callback.")
                .font(.caption2).foregroundStyle(.secondary)
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Text("GRAIN STRUCTURE")
                .font(.caption.weight(.bold)).foregroundStyle(.purple)
            sliders([.grainSize,.density,.position,.window,.reverse])
            Divider()
            Text("MOVEMENT & RANDOMNESS")
                .font(.caption.weight(.bold)).foregroundStyle(.purple)
            sliders([.scanSpeed,.pitch,.pitchJitter,.positionJitter,.panSpread])
            Divider()
            Text("VOICE ENVELOPE & OUTPUT")
                .font(.caption.weight(.bold)).foregroundStyle(.purple)
            sliders([.attack,.release,.gain])
        }
        .fileImporter(isPresented:$importPresented,allowedContentTypes:[.audio]) {
            result in
            switch result {
            case .success(let url):
                do {
                    let local=try StudioGranularSourceImporter.copyIntoLocalLibrary(url)
                    var updated=sound
                    updated.importedAudioPath=local.path
                    importError=nil
                    onChangeSource(updated)
                } catch {
                    importError=error.localizedDescription
                }
            case .failure(let error):
                importError=error.localizedDescription
            }
        }
    }
}
