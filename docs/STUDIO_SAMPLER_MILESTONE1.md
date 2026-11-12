# Studio Sampler — Milestone 1, native playback foundation

Branch: `feature/studio-sampler-native` (from `feature/studio-analog`).

Studio Sampler is an original, in-process, RAM-backed sampler for Studio.
It does not embed a commercial sample engine, plug-in, or third-party sampler
library. The current implementation deliberately leaves existing ARIA,
Audio Unit, fallback sampler, and Studio Analog paths in place.

## What this implementation includes

- Original C++17 `StudioSamplerDSP` with planar stereo Float32 rendering
  via a Swift `AVAudioSourceNode` bridge.
- Immutable, sampler-owned sample data, decoded and copied before attaching
  the render callback. Files are loaded with Apple's `AVAudioFile`.
- 1–64 voices (16 default), polyphonic note on/off, MIDI channel ownership,
  per-note velocity gain, equal-temperament pitch transposition, linear
  interpolation, basic 64-frame anti-click fades and oldest-voice stealing.
- One sample chosen per note from a versioned key-range and velocity-range
  mapping, favoring the closest recorded root. Zone overlap does not mix yet.
- A Studio instrument-browser action, **Load Sample…**, importing one audio
  file and assigning it to C4 (MIDI 60) across the keyboard.
- Per-track `studioSamplerPatch` project persistence; opening a project
  restores a native sampler in the legacy `AVAudioEngine` backend.
- Track mixing, panning, metering and stage acoustic send reuse the existing
  Studio routing. No new dedicated mixer or plug-in host is required.

## Explicit limitations

- **Not a release-quality streaming sampler:** decoded PCM is resident in RAM;
  each zone is capped at 10 million frames and an instrument at 128 zones.
- Importer initially creates a single full-keyboard zone at C4. Multi-sample
  mappings can already be represented in the model, but require a future UI.
- No ADSR, sustained looping, dynamic layer crossfades, pitch bend, CC
  modulation or sample-accurate sub-buffer MIDI offsets yet.
- Files are referenced by absolute path, not packaged with the project. If
  they are moved or macOS file permissions are revoked, Studio will need the
  original file restored. Persistent security-scoped bookmarks and portable
  instrument packaging are still required before shipping.
- The native sampler currently requires the legacy AVAudioEngine backend.
  Core Audio backend support must be implemented separately.
- Loading and decoding occurs outside the audio callback, but in the current
  UI path it is synchronous; a background import workflow is future work.

## Thread safety

- Sample maps and decoded frames never change while rendering.
- The render callback owns a strong reference to the sampler state.
- C++ rendering never allocates, locks, logs or touches disk.
- MIDI producers are serialized by a Swift lock OUTSIDE the render callback,
  feeding a bounded C++ SPSC command ring.
- Graph attach/detach uses Studio's existing stop/restart procedure.

## Test coverage

`Tests/StudioSamplerDSPStandalone/main.cpp` verifies valid/invalid mapping,
440 Hz pitch, stereo preservation, note transposition, MIDI note-off and
release to silence. The GitHub workflow builds the original DSP with Address
Sanitizer and Undefined Behavior Sanitizer on Linux.

`Tests/DAWCoreTests/StudioSamplerTrackIntegrationTests.swift` checks
offline `AVAudioEngine` rendering of an original test tone, stereo output,
missing sample paths, invalid mapping, and project backward compatibility.

Do not describe the Mac app integration as verified until the GitHub macOS
workflow has passed and a later listening milestone confirms playback.
