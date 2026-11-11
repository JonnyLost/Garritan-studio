# Studio Sampler — Mapping & Velocity Layer Editor

Status: Implemented on `feature/studio-sampler-native`, subject to macOS CI and hardware verification.

This extends the first native playback milestone without replacing the original
C++ sampler engine, Studio Analog synth, ARIA, or existing Audio Units.

## User workflow

1. Open a MIDI/instrument track's instrument browser and choose **Load Samples…**.
2. Select multiple original audio recordings (WAV/AIFF or formats read by AVAudioFile).
3. Studio copies the files into `~/Library/Application Support/GarritanStudio/SamplerSamples`
   before the file picker's temporary security-scoped access ends. Source files
   are never modified or deleted.
4. Studio builds a first-pass map from filenames:
   - C4, C#4, Db4, Bb3, etc. determine the recorded root note.
   - pp, mp, mf, ff, or velNN tokens determine **ordering** of velocity layers.
   - Roots divide the keyboard into adjacent zones at their midpoint.
   - Multiple recordings of the same note receive equal-size, non-overlapping
     initial velocity bands (unless there are >127 layers at one note).
   - Unrecognized filenames receive sequential roots from C4; these guesses
     must be checked before using the instrument seriously.
5. The Instruments lower workspace shows **Studio Sampler — Mapping** when
   the selected track uses Studio Sampler. Alternatively, open the mapping
   editor from the track's context menu or its Inspector.
6. Click a colored region or select it from the zone picker, then edit root
   note, lowest/highest key, and lowest/highest velocity. Duplicate and remove
   zones to arrange layers. The **Auto Map** button re-derives initial ranges.
7. **Apply Mapping** rebuilds the native instrument from the draft and persists
   it on the track; **Discard Changes** restores the saved map.

## Architectural guarantees

- Each original sample is copied to stable app-managed local storage.
- No third-party sampling DSP, content or plug-in is used.
- The original `StudioSamplerPatch` model remains version 1 with versioned
  editable zones. The new mapping builder creates normal `StudioSamplerZone`
  entries; no new persistence migration is required.
- Draft changes never alter the real-time C++ sample/zone array. Apply loads a
  complete new native instance off the audio callback, then uses existing
  graph-attachment logic.
- The engine currently selects ONE matching zone per note and velocity,
  choosing the nearest recorded root. Visual overlaps are for manual
  preparation; multiple simultaneously sounding crossfade layers require
  a future playback milestone.
- RAM loading is bounded to 10 million source frames per file and 32 million
  across a loaded instrument. Disk streaming and larger libraries follow later.

## Known follow-on work

- Async sample decoding off the main thread (the file copy is async already).
- Sample-library orphan cleanup, explicit sample relocation and portable
  project/instrument packages.
- Recognize more naming conventions and optionally detect pitch from waveforms.
- Drag handles and piano-key audition within the editor.
- Velocity and CC crossfade synthesis, round-robin, ADSR, sustain loops,
  large-library disk streaming, and sample-accurate MIDI.
- Native sampler support for the alternative CoreAudioBackend.

## Automated verification

- `StudioSamplerMappingBuilderTests`: filename parsing, key boundaries,
  velocity layering, deterministic fallback, limits, sample library copying.
- `StudioSamplerTrackIntegrationTests`: existing audio rendering and project
  compatibility checks.
- `StudioSamplerDSPStandalone/main.cpp`: DSP pitch, stereo, note-offs,
  velocity-layer and note-range selection; Linux AddressSanitizer/UBSan.
- GitHub Actions on macOS: `swift build`, `swift test --parallel`,
  release app build.

The Mac audio path still requires a single human audition milestone after
CI passes; do not label it listening-verified before that.
