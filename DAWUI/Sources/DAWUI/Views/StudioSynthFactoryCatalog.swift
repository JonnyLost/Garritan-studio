import Foundation
import DAWCore

/// One index for every Studio-owned factory sound. The picker deliberately
/// reads the original engine libraries instead of maintaining another list
/// of names, paths, or copied parameter data.
struct StudioSynthFactorySound: Identifiable {
    let id: String
    let name: String
    let engineName: String
    let category: String
    let summary: String
    let patch: StudioSynthPatch

    var instrumentPath: String {
        "Synth/\(engineName)/\(category)/\(name)"
    }

    /// Factory templates are immutable. Each selected track gets fresh layer,
    /// modulation-route and MIDI-learn identities, with all referenced layer
    /// IDs retargeted together. No two tracks share editable voice identity.
    func instantiatePatch() -> StudioSynthPatch {
        var instance = patch
        var layerIDs: [UUID: UUID] = [:]
        for index in instance.layers.indices {
            let oldID = instance.layers[index].id
            let newID = UUID()
            instance.layers[index].id = newID
            layerIDs[oldID] = newID
        }
        if var modulation = instance.modulation {
            for index in modulation.routes.indices {
                let oldID = modulation.routes[index].layerID
                modulation.routes[index].layerID = layerIDs[oldID] ?? oldID
                modulation.routes[index].id = UUID()
            }
            instance.modulation = modulation
        }
        if var midiControls = instance.midiControls {
            for index in midiControls.mappings.indices {
                var mapping = midiControls.mappings[index]
                mapping.id = UUID()
                if case .parameter(let oldID, let destination) = mapping.target,
                   let newID = layerIDs[oldID] {
                    mapping.target = .parameter(layerID: newID, destination: destination)
                }
                midiControls.mappings[index] = mapping
            }
            instance.midiControls = midiControls
        }
        return instance
    }
}

enum StudioSynthFactoryCatalog {
    static let libraryName = "Studio Synth"

    static let sounds: [StudioSynthFactorySound] = {
        var result: [StudioSynthFactorySound] = []

        for preset in StudioAnalogFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "analog:\(preset.id)", name: preset.name,
                engineName: "Analog", category: preset.category.title,
                summary: preset.summary,
                patch: StudioSynthPatch(layers: [
                    StudioSynthLayer(engine: .analog, gain: 0.75,
                                     analogPatch: preset.patch)
                ])
            ))
        }
        for preset in StudioFMFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "fm:\(preset.id)", name: preset.name,
                engineName: "FM", category: preset.category.title,
                summary: preset.summary,
                patch: StudioSynthPatch(layers: [
                    StudioSynthLayer(engine: .fm, gain: 0.75,
                                     fmPatch: preset.patch)
                ])
            ))
        }
        for preset in StudioWavetableFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "wavetable:\(preset.id)", name: preset.name,
                engineName: "Wavetable", category: preset.family,
                summary: preset.summary,
                patch: StudioSynthPatch(layers: [
                    StudioSynthLayer(engine: .wavetable, gain: 0.75,
                                     wavetablePatch: preset.patch)
                ])
            ))
        }
        for preset in StudioAdditiveFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "additive:\(preset.id)", name: preset.name,
                engineName: "Additive", category: preset.family,
                summary: preset.summary,
                patch: StudioSynthPatch(layers: [
                    StudioSynthLayer(engine: .additive, gain: 0.75,
                                     additivePatch: preset.patch)
                ])
            ))
        }
        for preset in StudioGranularFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "granular:\(preset.id)", name: preset.name,
                engineName: "Granular", category: preset.family,
                summary: preset.description,
                patch: StudioSynthPatch(layers: [
                    StudioSynthLayer(engine: .granular, gain: 0.75,
                                     granularPatch: preset.patch)
                ])
            ))
        }
        for preset in StudioPhysicalFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "physical:\(preset.id)", name: preset.name,
                engineName: "Physical Modeling", category: preset.family,
                summary: preset.summary,
                patch: StudioSynthPatch(layers: [
                    StudioSynthLayer(engine: .physical, gain: 0.75,
                                     physicalPatch: preset.patch)
                ])
            ))
        }
        for preset in StudioSynthHybridFactoryLibrary.presets {
            result.append(StudioSynthFactorySound(
                id: "hybrid:\(preset.id)", name: preset.name,
                engineName: "Hybrid", category: preset.family,
                summary: preset.summary, patch: preset.patch
            ))
        }
        return result.sorted {
            if $0.engineName != $1.engineName {
                return $0.engineName.localizedStandardCompare($1.engineName) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }()

    static func sound(id: String) -> StudioSynthFactorySound? {
        sounds.first { $0.id == id }
    }
}
