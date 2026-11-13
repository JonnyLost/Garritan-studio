import Foundation

/// Reuse the completed Sampler's managed recordings as Granular sources.
/// The Granular DSP still decodes a bounded PCM window on the control thread;
/// it does not open sample files inside its audio render callback.
public struct StudioGranularSamplerSource: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let audioURL: URL

    public init(id: String, title: String, audioURL: URL) {
        self.id = id
        self.title = title
        self.audioURL = audioURL
    }
}

public enum StudioGranularSamplerBridge {
    /// List only verified, resolved recordings on Sampler tracks. This leaves
    /// the original recording owned by Sampler and avoids duplicate imports.
    public static func sources(in project: Project) -> [StudioGranularSamplerSource] {
        var result: [StudioGranularSamplerSource] = []
        var seen = Set<String>()
        for track in project.tracks {
            guard let patch = track.studioSamplerPatch,
                  let resolved = try? StudioSamplerSampleLibrary.resolve(patch)
            else { continue }
            for zone in resolved.zones {
                let url = zone.sampleURL.standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path),
                      seen.insert(url.path).inserted else { continue }
                result.append(StudioGranularSamplerSource(
                    id: url.path,
                    title: "\(track.name) · MIDI \(zone.rootNote) · \(url.lastPathComponent)",
                    audioURL: url))
            }
        }
        return result.sorted { $0.title < $1.title }
    }

    /// Also expose app-managed Sampler recordings, including instruments
    /// created by Synth capture and the Sampler's Instrument Factory.
    public static func librarySources() -> [StudioGranularSamplerSource] {
        guard let folder = try? StudioSamplerSampleLibrary.libraryDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys:
                    [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { url in
            guard let props = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return props.isRegularFile == true && props.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                StudioGranularSamplerSource(
                    id: url.path, title: url.lastPathComponent, audioURL: url)
            }
    }
}
