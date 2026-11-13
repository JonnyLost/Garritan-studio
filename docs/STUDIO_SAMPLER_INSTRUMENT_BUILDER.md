# Studio Sampler — Instrument Builder / Portable Library (Milestone 1)

Implementation branch: feature/studio-sampler-native. Do not merge without product-owner approval.

## Create and save an instrument

1. On a MIDI/instrument track, choose **Open Studio Sampler** (not **Quick Import Samples**).
2. In its mapping editor, choose **Add Samples…**, then select one or more WAV/AIFF/audio files. Studio imports app-owned copies.
3. Studio Auto Map recognizes filename hints:
   - MIDI pitch: C4, F#3, Bb2, midi60, note60, n60
   - Velocity: ppp, pp, p, mp, mf, f, ff, fff, v90, vel100, velocity120
   - Alternates: rr1–rr8, take1–take8, alt1–alt8
   - Note-off samples: release, rel, noteoff
   - Articulations: legato, staccato, pizzicato, spiccato, tremolo, harmonics, marcato, sforzando, fluttertongue, trill, collegno, sulponte
4. Review key and velocity ranges. Edit zone root notes, articulation, round-robin, sample start/end, fades and loop points. Everything stays in an editable draft until **Apply Mapping**.
5. Use **Instruments → Save to Studio Library…** to create a searchable saved instrument with name, category and tags.
6. Use **Instruments → Export Portable Instrument…** to create a standalone .studioinstrument package, including the recordings.
7. Use **Instruments → Browse Instrument Library…** to search by name, category or tag and load a saved instrument. Packages can be removed here with confirmation.
8. Use **Instruments → Import .studioinstrument…** to load an instrument sent from another Mac, or backed up elsewhere.

## File format and compatibility

- A .studioinstrument is a macOS package directory containing manifest.json and Samples/.
- Manifest format version 1 contains name/category/tags and the existing StudioSamplerPatch structure (zones, dynamic crossfade settings, CC defaults, envelopes, articulations, keyswitches, loop, trim and fade data).
- Each unique recording is copied once into the package, regardless of the number of zones referencing it. Samples retain their original audio format (no lossy compression or rewrite).
- Manifest sample paths are relative to the package. After import, all recordings are copied into Studio's private sampler sample directory and the loaded patch is rebuilt with managed references.
- Every recording has a SHA-256 digest and byte length. Import refuses damaged files, unsafe paths and symlinks, before touching the active instrument.
- Existing project JSON, saved sampler patches, legacy absolute file references, sample relinking and DSP playback remain backward-compatible.
- Installed packages live under Application Support/GarritanStudio/SamplerInstruments. Track samples live separately in Application Support/GarritanStudio/SamplerSamples.
- Deleting a saved library package does not delete recordings referenced by active projects. Exporting also does not alter the track or its source files.
- Export refuses to overwrite an existing package; select a new filename or move the existing backup manually.

## Limits and known follow-on work

- Current patch limit: 128 zones and 15 additional articulations; each articulation gets an independent automatically inferred key map.
- Auto Map uses explicit filename hints and nearest-root assignment, not pitch detection, loudness measurement or intelligent classification of arbitrary audio. Unrecognized filenames get deterministic fallback roots and should be reviewed.
- Duplicate sample files are deduplicated by source location inside a single export; independently imported files are currently not content-deduplicated in the private library. Avoid saving hundreds of duplicate copies unnecessarily.
- This milestone does not implement advanced transition-sample legato, microphone groups, or original factory instruments; those belong to later sampler milestones.
- Mac build and automated regression checks run in .github/workflows/studio-sampler.yml. A consolidated real Mac/audio workflow test remains required before merging.

## Safety and architecture

- File IO and SHA-256 hashing run off the audio thread. In the editor, imports and exports are performed in background tasks.
- Save/export uses a staging directory and atomic move into place; failed exports remove their staging contents.
- Import verifies package integrity before copying recordings; the existing batch importer rolls back newly copied files if an import copy fails.
- Security-scoped access to user-selected packages is opened/closed for the duration of import.
- A package is data, not executable plugin code. The native sampler and realtime DSP are unchanged by this milestone.
