# Studio Synth — Phase 1: unified native instrument

Branch: feature/studio-synth (created from feature/studio-fm). No branches are merged.

## Delivered architecture

StudioSynthPatch is versioned and persisted in each project track. It owns up
to four independent native synthesis layers, with stable UUID, sound engine,
saved native patch, on/off state, gain and pan. Analog and FM parameter identities
and their legacy project/preset file formats are unchanged.

StudioSynthInstrument reuses the existing original C++ Analog and FM voice
engines through one parent AVAudioMixerNode and one mixer per active layer.
Inactive layers create no DSP engine. No audio callback gains locks, allocations,
file I/O or plugin-host dependencies. Track MIDI fans out to all active layers
and the normal track mixer / stage acoustics remain in place.

The instrument browser exposes Studio Synth. The dedicated Studio Synth panel
offers a Hybrid/Layers overview, independent Analog and FM editors, individual
sound templates, one-to-four layers, per-layer level/pan, and original factory
sound selection. Editor tabs do not mute or overwrite other layers.

## Not finished yet

- Wavetable synthesis engine/editor; then additive, granular, physical models.
- Cross-layer modulation matrix, shared envelopes/effects, unified preset bank.
- Advanced analog modular patchboard within the new hybrid interface.
- Sample-accurate render-clock timelines for FM/hybrid sequencing.
- Full consolidated Mac listening and performance validation.

## Automated checks

.github/workflows/studio-synth.yml runs standalone C++ sanitizers for both
renderers and macOS swift build, swift test --parallel and release DAWApp build.
StudioSynthTests contains project round-trip, invalid-patch, live-MIDI, runtime
layer-configuration and offline AVAudioEngine hybrid-render regression tests.

Do not mark tests passed until a complete workflow result is observed.
Do not merge without explicit user authorization.
