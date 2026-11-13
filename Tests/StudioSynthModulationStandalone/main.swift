import Foundation

// Standalone Linux checks for Studio Synth's pure Swift modulation core.
// These run even when GitHub macOS runners are unavailable.
var patch = StudioSynthPatch()
patch.layers.append(StudioSynthLayer(engine: .wavetable))
let ids = patch.layers.map(\.id)
var settings = StudioSynthModulationSettings(macro1: 1)
let target = StudioSynthModDestination.fm(.feedback)
settings.routes.append(StudioSynthModRoute(
    source: .macro1, layerID: ids[1], destination: target, depth: 0.3))
settings.routes.append(StudioSynthModRoute(
    source: .macro1, layerID: ids[1], destination: target, depth: -0.1))
settings.routes.append(StudioSynthModRoute(
    source: .lfo1, layerID: ids[0],
    destination: .analog(.filterCutoff), depth: 0.2))
settings.routes.append(StudioSynthModRoute(
    source: .envelope, layerID: ids[2],
    destination: .wavetable(.osc1Position), depth: 0.4))
patch.modulation = settings
assert(patch.validate())
let encoded = try JSONEncoder().encode(patch)
let decoded = try JSONDecoder().decode(StudioSynthPatch.self, from: encoded)
assert(decoded == patch)
settings.lfo1Rate = 1
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 0.25, settings: settings, envelope: 0, wheel: 0) - 1) < 0.0001)
settings.lfo2Rate = 1
assert(abs(StudioSynthModulationMath.signal(
    .lfo2, seconds: 0, settings: settings, envelope: 0, wheel: 0) + 1) < 0.0001)
assert(abs(StudioSynthModulationMath.signal(
    .lfo2, seconds: 0.5, settings: settings, envelope: 0, wheel: 0) - 1) < 0.0001)
// Standalone sync checks run on Linux even without a macOS CI runner.
var synced = StudioSynthModulationSettings(lfo1Rate: 1, lfo2Rate: 1)
synced.lfo1Sync = StudioSynthLFOSync(note: .quarter)
synced.lfo2Sync = StudioSynthLFOSync(note: .eighth)
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 0.125, settings: synced,
    envelope: 0, wheel: 0, bpm: 120) - 1) < 0.0001)
assert(abs(StudioSynthModulationMath.signal(
    .lfo2, seconds: 0.125, settings: synced,
    envelope: 0, wheel: 0, bpm: 120) - 1) < 0.0001)
synced.lfo1Sync = StudioSynthLFOSync(note: .quarter, timing: .dotted)
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 0.1875, settings: synced,
    envelope: 0, wheel: 0, bpm: 120) - 1) < 0.0001)
synced.lfo1Sync = StudioSynthLFOSync(note: .quarter, timing: .triplet)
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 1.0 / 12, settings: synced,
    envelope: 0, wheel: 0, bpm: 120) - 1) < 0.0001)
synced.lfo1Sync = StudioSynthLFOSync(note: .quarter)
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 0.25, settings: synced,
    envelope: 0, wheel: 0, bpm: 60, beats: 0.375)
    - Float(sin(0.75 * Double.pi))) < 0.0001)
synced.lfo1Phase = 0.25
synced.lfo2Phase = 0.5
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 0, settings: synced,
    envelope: 0, wheel: 0, bpm: 120) - 1) < 0.0001)
assert(abs(StudioSynthModulationMath.signal(
    .lfo2, seconds: 0, settings: synced,
    envelope: 0, wheel: 0, bpm: 120) - 1) < 0.0001)
synced.lfo1Sync = StudioSynthLFOSync(note: .sixtyFourth)
synced.routes = [StudioSynthModRoute(
    source: .lfo1, layerID: ids[0], destination: .analog(.filterCutoff))]
assert(StudioSynthModulationMath.controlRate(synced, bpm: 120) == 256)
synced.routes[0].enabled = false
assert(StudioSynthModulationMath.controlRate(synced, bpm: 120) == 50)
synced.routes[0].enabled = true
synced.lfo1Sync = StudioSynthLFOSync(note: .quarter)

let syncedRoundTrip = try JSONDecoder().decode(
    StudioSynthModulationSettings.self,
    from: JSONEncoder().encode(synced))
assert(syncedRoundTrip == synced)
var oldSyncJSON = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(synced)) as! [String: Any]
oldSyncJSON.removeValue(forKey: "lfo1Sync")
oldSyncJSON.removeValue(forKey: "lfo2Sync")
oldSyncJSON.removeValue(forKey: "lfo1Phase")
oldSyncJSON.removeValue(forKey: "lfo2Phase")
let legacySync = try JSONDecoder().decode(StudioSynthModulationSettings.self,
    from: JSONSerialization.data(withJSONObject: oldSyncJSON))
assert(legacySync.lfo1Sync == nil && legacySync.lfo2Sync == nil)
assert(legacySync.lfo1Phase == nil && legacySync.lfo2Phase == nil)
assert(abs(StudioSynthModulationMath.signal(
    .lfo1, seconds: 0.25, settings: legacySync,
    envelope: 0, wheel: 0, bpm: 60) - 1) < 0.0001)

var adsr = StudioSynthModulationEnvelope()
adsr.trigger()
assert(abs(adsr.advance(seconds: 0.08, settings: settings) - 1) < 0.0001)
_ = adsr.advance(seconds: 0.15, settings: settings)
assert(abs(adsr.advance(seconds: 0.15, settings: settings) - 0.7) < 0.0001)
adsr.release()
_ = adsr.advance(seconds: 0.2, settings: settings)
_ = adsr.advance(seconds: 0.2, settings: settings)
assert(adsr.advance(seconds: 0.2, settings: settings) == 0)

// Verify two routes to one destination add rather than overwrite, changing
// the unmodulated knob value is preserved, and removing routes restores it.
let lock = NSLock()
var nativeValue: Float = 0.1
func get() -> Float {
    lock.lock()
    defer { lock.unlock() }
    return nativeValue
}
func put(_ value: Float) {
    lock.lock()
    nativeValue = value
    lock.unlock()
}
var onlyMacro = settings
onlyMacro.routes = Array(onlyMacro.routes.prefix(2))
let worker = StudioSynthModulationWorker(
    settings: onlyMacro,
    read: { _, _ in get() },
    write: { _, _, value in put(value); return true })
assert(abs(get() - target.apply(base: 0.1, normalizedOffset: 0.2)) < 0.0001)
assert(worker.setBase(layer: ids[1], destination: target, value: 0.5))
assert(abs(get() - target.apply(base: 0.5, normalizedOffset: 0.2)) < 0.0001)
onlyMacro.routes = []
worker.update(onlyMacro)
assert(abs(get() - 0.5) < 0.0001)
var invalid = patch
invalid.modulation?.routes[0].destination = .wavetable(.osc1Position)
assert(!invalid.validate())
invalid = patch
invalid.modulation?.routes[0].depth = .infinity
assert(!invalid.validate())

print("Studio Synth modulation standalone Swift checks passed")
