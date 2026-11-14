# Studio Synth v1 — Final Development Handoff

**Branch:** `integration/studio-synth-sampler-bridge`
**Merge status:** Not merged. All feature branches remain independent.
**Scope:** Native Synth v1 development closeout; macOS listening/creative acceptance
is a subsequent, consolidated milestone.

## What is implemented

- Native Analog, FM, Wavetable, Additive, Granular and Physical engines.
- Individual instruments and up to four layered Hybrid engines.
- Factory sound browsers by engine and family.
- Live parameter editing, layer gain/pan, MIDI note and controller delivery.
- Cross-engine LFO/envelope/Macro modulation and MIDI Learn.
- Per-layer, project-persistent Synth automation points editable at the
  playhead. Automation changes control-rate performance state without rewriting
  preset settings and releases its override at Stop.
- A versioned `.studiosynth` user-preset library with Save, Load, Rename,
  Import, Show in Finder and confirmed Delete. Presets contain layer settings,
  modulation and MIDI Learn assignments.
- Sound replacement validates the patch, reconciles orphaned Synth automation
  targets and participates in the normal track undo path.
- Synth-to-Sampler multisampling and instrument package export.
- Granular reuse of Studio Sampler files and a bounded shared PCM cache.

## Preset format and sample dependency

The `.studiosynth` file stores **synthesis parameters**, not recorded audio.
Granular factory sounds are self-contained; if a custom Granular layer imports
a WAV or other audio file, that file is an external dependency.

- Studio displays a warning in the preset-save dialog.
- Loading a saved sound with a missing file reports the original location
  instead of quietly loading another source.
- For moving to another Mac, keep the external recording with the preset,
  or export the playable sound as a native Sampler instrument through
  **Make Sampled Instrument**.
- Import assigns a new UUID and does not overwrite an existing user sound.
  Display-name collisions require renaming one of the sounds first.

## Project compatibility

Legacy Studio Analog/FM patches are unchanged. The six-engine Synth patch
uses the existing project Codable structure. The automation parameter enum
adds a separate, stable Synth layer target; existing lanes such as volume,
pan, send and plugin are unaffected.

A new Hybrid sound may have different layer UUIDs from the previous sound.
Orphaned Synth automation is deliberately discarded on replacement; existing
track volume/pan/send and still-valid layer lanes are retained.

## Automated verification

The integration branch's GitHub Actions workflow performs:

1. Linux Swift source syntax checks and C++ AddressSanitizer/UBSan harnesses
   for Sampler, Granular and shared PCM lifetime.
2. Full macOS Swift package development build.
3. Full macOS XCTest suite, including native Synth factory preset consistency,
   cross-engine modulation and MIDI, automation and custom preset management,
   sampled instrument creation, project persistence and shared PCM.
4. Optimized macOS `DAWApp` release build.

Check the latest CI run before using a build in production. A code or CI pass
does not establish subjective realism, preset loudness matching, mouse/keyboard
ergonomics or audio-device stability on the user's MacBook.

## One consolidated on-Mac creative test

Perform once, rather than interrupting development with repetitive tests:

1. Launch Studio, make one individual native Synth track, load a factory sound
   from each of the six engines, audition notes, velocity and modulation wheel.
2. Make a two-layer Hybrid; verify layer mix and MIDI expression, plus no
   stuck notes after Stop or a sound change.
3. Save the Hybrid to My Sounds, switch sounds, reopen it, rename it,
   save/reopen the project and confirm the same sound returns.
4. Create an automation lane, draw/play two values at different beats, edit
   while playing and verify Stop restores the unautomated value.
5. Import an audio recording into Granular; confirm its source is audible,
   then capture a Synth into a native Sampler instrument and play that track.
6. Play a moderate multi-track composition on the MacBook, audition the
   Orchestral Stage/reverb sends, stop/restart and perform a stereo bounce.
7. Listen critically to physical-model winds/bows/brass, compare factory
   preset output levels and capture any sound/UX issues in one feedback pass.

**Exit criteria:** no crashes, stuck notes, missing project data or audio dropouts
during normal composing; patch and project round-trips work; the sounds are
musically useful. Physical-model realism and factory loudness remain subjective
acceptance items, not claims established by automated tests.

## Explicitly out of scope for v1

- Sample-accurate Synth parameter automation (currently control-rate).
- Embedding external Granular recordings inside `.studiosynth` JSON.
- Shared cache pages for the long disk-streamed Sampler sources.
- Guaranteed acoustic realism of every physical modeling preset.
- Integration branch merge (requires the product owner's explicit approval).

Native Synth v1 development can be considered **code-complete after all current
CI jobs pass**. Final production-ready acceptance follows the consolidated
MacBook test and any findings it reveals.
