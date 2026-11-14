# Studio — Track Creation, Native Instrument Picker & Mixer Sends

**Date:** November 13, 2026  
**Branch:** \`feature/studio-track-workflow\`  
**Base:** \`integration/studio-synth-sampler-bridge\` at \`dc556f4db716529748a7b7fa822adb4c890a0742\`  
**Integration status:** Feature branch only. Do not merge without product-owner authorization.

## Product decisions

The everyday Add Track menu now offers exactly:

1. **Add Instrument** — creates an instrument/MIDI-capable track and opens the unified Instrument Picker; select an ARIA orchestral sound or native Synth factory preset.
2. **Add Sampler** — creates an independent native Studio Sampler track with a supported, blank mapping. The sampler remains silent and uses no sample loading or worker thread until the first sample is added.
3. **Add Synth** — creates an independent built-in Studio Synth instance, with its editable native patch and a dedicated bottom workspace.
4. **Add Audio** — creates an empty audio track, ready for recording.

Old MIDI tracks remain supported in projects and the internal model. MIDI recording and editing are still the instrument track's musical content.

## What exists in the current code

- A new track connects through AudioEngine's per-track dry output and Concert Hall send, with a persisted stage position and send trim.
- The track-creation method creates the mixer graph and Synth renderer before registering the new model or Undo action. On native load failure, it detaches the temporary channel rather than leaving a broken track.
- The existing engine's empty Sampler workflow (\`StudioSamplerPatch(zones: [])\`) is reused rather than generating a fake sample.
- The Instrument Picker now reads **Studio Analog, FM, Wavetable, Additive, Granular, Physical Modeling, and Hybrid** factory libraries directly. The compact picker groups Synth sounds by engine; the expanded browser filters by family and engine type.
- Native factory selection applies a full, portable native patch; its layers, MIDI-learn mappings and modulation routes are assigned independent per-track identities.
- Mixer channel strips expose the first four Audio Unit insert slots, extend to show existing additional slots, and provide a 0–200% Concert Hall send trim. These operate on Studio's existing audio insert and reverb engines; no new third-party DSP has been introduced.
- Track menu commands and keyboard shortcuts use the same track creation command as the timeline.

## Scope and verification

- Native Synth + Sampler bridge baseline \`dc556f4d\` passed its workflow before work began.
- New branch runs the full bridge workflow: Swift syntax parse, ASan/UBSan standalone DSP checks, macOS debug build, DAWCore and new DAWUI catalog tests, optimized DAWApp build.
- New tests verify all seven native engine families, 1:1 factory catalog/library coverage, sound identity and patch validity, independent layer instances and Hybrid modulation references.
- Do not claim an actual Mac/ARIA hardware audition or project integration merge from these CI checks.

## Next milestone: Audio Mixdown and Flexible Stems

This branch does **not** implement rendering/exporting files. Its stable per-track identities and routed mixer channels are the foundation for:

- Stereo mixdown, mono mixdown, individual track export.
- Stem definitions driven by selected track IDs and/or instrument families.
- Configurable inclusion of each stem's *own* shared reverb sends and tails, without leaking reverb from unselected tracks.
- Choice of pre-/post-master effects and export conventions; render loop/time range, tails, sample rate, bit depth and filenames.
- Real-time-compatible and deterministic bounce where native AVAudioEngine/AU instruments allow it; explicit fallback for AUs without offline render support.
- Immutable render snapshots; disable live session mutations during a bounce, preserve transport/solo/mute state afterward, and write files atomically.
- Stem-isolation tests across native synth, sampler, ARIA/Audio Unit and Audio tracks; performance profiles on MacBook.

Do **not** use repeated live solo toggling on the user's project as the final implementation: shared hall tails and non-linear master processing require explicit isolation semantics.
