import Foundation

/// Keep track automation consistent when replacing a Studio Synth sound.
///
/// Layer UUIDs are stable only within their own patch. Replacing a Hybrid
/// with another preset can invalidate per-layer targets, even when both
/// patches contain the same synthesis engine. Preserve unrelated track
/// automation and valid targets, but discard orphaned Synth lanes.
public enum StudioSynthAutomationConsistency {
    public static func reconcile(_ lanes: [AutomationLane],
                                 for patch: StudioSynthPatch) -> [AutomationLane] {
        let valid = Dictionary(uniqueKeysWithValues: patch.layers.map {
            ($0.id, $0)
        })
        return lanes.filter { lane in
            guard case .studioSynth(let layerID, let destination) = lane.parameter
            else { return true }
            guard let layer = valid[layerID] else { return false }
            // Muting a layer must not destroy the automation a composer
            // created for that sound. Only deleted or retargeted layers
            // become orphaned; PlaybackEngine skips muted layers at runtime.
            return layer.engine == destination.engine &&
                destination.isContinuouslyModulatable
        }
    }

    /// A saved user preset contains sound settings only. Source recordings
    /// imported into Granular remain external files: don't silently claim
    /// that the .studiosynth JSON contains those recordings.
    public static func missingGranularSources(
        in patch: StudioSynthPatch,
        fileManager: FileManager = .default
    ) -> [String] {
        patch.layers.compactMap { layer -> String? in
            guard layer.engine == .granular,
                  let path = layer.granularPatch?.importedAudioPath,
                  !fileManager.fileExists(atPath: path) else { return nil }
            return path
        }
    }

    public static func usesExternalGranularAudio(
        _ patch: StudioSynthPatch
    ) -> Bool {
        patch.layers.contains {
            $0.engine == .granular &&
                $0.granularPatch?.importedAudioPath != nil
        }
    }
}
