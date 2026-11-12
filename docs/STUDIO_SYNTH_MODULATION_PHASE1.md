# Studio Synth — Shared Modulation Matrix (Phase 1)

Development branch: \`feature/studio-synth\`, stacked draft PR #4.
No changes are merged into the original Analog, FM, or Sampler branches.

## Implemented

- **One routing matrix** embedded in the versioned \`StudioSynthPatch\`,
  with up to 24 independent routes targeting parameter controls on any
  Analog, FM or Wavetable layer.
- Sources: independent sine LFO 1 (0.03–15 Hz), triangle LFO 2,
  a shared retriggering monophonic ADSR envelope with sustain-pedal
  awareness, incoming global MIDI CC1, and editable Macro 1.
- Signed normalized modulation amounts in \`-1...+1\`. Multiple routes
  to the same parameter are added together (never last-writer-wins).
  The final destination is range-clamped; logarithmic controls such as
  filter cutoff and FM operator ratios are modulated in their *normalized*
  perceptual slider space. Discrete waveform and FM algorithm IDs are
  never legal destinations.
- A shared routing workspace inside Studio Synth with source selection,
  per-layer destination selection, active toggle, signed amount control,
  LFO and ADSR rate/envelope controls, editable Macro 1, route removal.
- Route updates (including Macro) are applied to the existing native
  instrument **without reloading the AVAudioEngine graph** or resetting
  active notes. The saved parameter base is kept separate from the live
  modulated value, and removal of routes restores the base patch.
- Both LFOs now support independent **Free** (0.03–15 Hz) or **Sync**
  modes. Sync offers 1/1, 1/2, 1/4, 1/8, 1/16, 1/32 and 1/64 durations,
  each with straight, dotted or triplet timing. Project tempo supplies BPM;
  saved Free mode frequencies remain intact when Sync is selected.
- Integrated beat phase runs continuously on the existing worker and never
  resets when project BPM changes. Live changes update every loaded shared
  synth instrument via PlaybackEngine's existing tempo subscription; newly
  loaded instruments receive the current tempo. No extra DSP callbacks,
  real-time timers or third-party clock dependencies were introduced.
- Sync is optional in the existing version-1 patch schema: absent sync
  keys decode to Free mode, so older factory patches and saved projects
  remain readable without migration.
- The 50Hz control worker runs only if routes are enabled. It uses a
  private serial dispatch queue (QoS utility), 5-ms scheduler leeway,
  and the same atomic C++ parameter setters already used by the synths.
  No locks, file I/O, Swift object creation, or modulation math has been
  introduced into any DSP render callback.
- Existing non-hybrid Studio Analog, FM and Wavetable patches are unchanged.
  Missing matrix data decodes to nil in older projects.

## Honest limitations

- This phase is **control-rate modulation**, not audio-rate or sample-accurate.
  Cross-layer modulation is globally timed by a 50Hz worker, so envelope
  retriggers and CC1 changes may have up to a control-tick of latency/jitter.
- The shared ADSR is monophonic and retriggers on note-on. Independent
  per-voice ADSRs remain inside the underlying synthesis engines.
- CC1 is the last received wheel value across MIDI channels, intended for
  global cross-layer macro behavior. Per-channel/per-note expression matrix
  routing, MIDI learn and step sequencers are later steps.
- Worker is active for the life of an instrument with enabled routes, even
  while silent. This is low-cost at 50Hz, but true idle-voice suspension and
  battery profiling remain follow-up work.

## Verification

- Regression tests cover model validation, destination engine matching,
  non-finite depths, maximum routes and UUID uniqueness, optional old-project
  decoding, deterministic LFO/ADSR samples, cross-engine Macro 1 modulation,
  additive multi-route behavior, preserving edited base controls and restoring
  baselines after route deletion. Sync checks cover all 21 note-duration
  variants, straight/dotted/triplet math, old-JSON decoding, patch round trips
  and beat-phase continuity at live BPM changes. The Linux standalone test
  additionally exercises sync math without a macOS SDK.
- CI: Swift syntax parse on Linux, the original Analog/FM/Wavetable C++
  sanitizer tests, macOS \`swift build\`, \`swift test --parallel\` and
  release \`DAWApp\` build.
- Final macOS interactive listening, modulation speed, CPU/battery and
  audio timing are not yet confirmed.

Do not merge branches without explicit user authorization.
