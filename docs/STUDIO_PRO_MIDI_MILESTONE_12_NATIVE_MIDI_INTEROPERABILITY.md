# Garritan Studio — Professional MIDI Milestone 12
## Native Standard MIDI File import and reversible interoperability

**Date:** 2026-11-14  
**Feature branch:** `feature/pro-midi-file-export`, stacked draft PR #11 on `feature/pro-midi-sequencer`  
**Merge status:** No branches merged. Other Studio workstreams are unchanged.

## Why this milestone is intentionally conservative

Studio's source of truth is its editable `.dawproj`. A generic Standard MIDI File contains MIDI channel data and conductor events, but cannot carry Studio semantic per-note articulation IDs and user-created maps. Performance-mode export bakes the configured instrument's triggers; musical-only export is the safe default for other instruments.

The active `PlaybackEngine` schedules from `StudioMIDISessionPlanner` using `project.tempo.bpm`, and its per-clip scheduler does **not** currently expand `Clip.isLooped` into multiple MIDI passages. It would be incorrect to silently fabricate loop playback that Studio does not actually produce. The exporter therefore **continues to reject unexpanded clip loops**. This is a deliberate fidelity guard, not a claim that looping is fully implemented.

The SMF writer already represents stepped project tempo and meter changes at their authored musical beats and rejects continuous tempo ramps. The importer recovers these conductor changes into the Studio project, but hearing the complete step-tempo performance within the Studio live transport will require a separate playback-tempo-map upgrade. MIDI file interchange should not be presented as a hardware audition.

## Delivered

### Native SMF reader

`StandardMIDIFileImporter.decode(_:name:)` is a self-contained original DAWCore parser. It supports:
- Standard MIDI File formats **0 and 1**, with positive PPQ timing, including source files using running status
- Multiple named music tracks, note-on/note-off pairing, release velocity, overlapping chord notes, explicit unmatched note-offs, and MIDI channel preservation
- Controller changes (including CC1/11/64), 14-bit pitch bend, program changes, channel/poly aftertouch and F0 SysEx
- Conductor tempo and time-signature changes; initial tempo/meter metadata becomes the project's defaults
- New MIDI regions with note durations in quarter-note beats, independent of the source file's PPQ
- Bounded reads, validated chunk lengths and VLQ durations, per-track end-of-track checks, event/tick/file size caps; malformed or unclosed notes fail before any project replacement

**Deliberate unsupported input:** SMPTE-time files, formats other than 0/1, F7 SysEx continuations and tempos outside Studio's supported range are rejected. Non-musical SMF metadata such as arbitrary text and key-signature meta-events is not retained because the current project model has no equivalent fields.

### Safe document import

`ProjectFileManager.importMIDI(from:)` validates and creates a new `Project` without touching the current project. File → **Import MIDI as New Project…** requires the current document to be saved before opening a replacement, reads the file before clearing existing instrument instances, and marks the imported project as unsaved. Imported MIDI tracks intentionally have no automatically assigned commercial instrument patches.

### Automated interchange checks

`StandardMIDIFileImporterTests` includes:
1. Full native `export → import → export → import` with named tracks, tempo/meter changes, two channels, CC11, signed full-resolution bend, program changes, pressure and musical note duration
2. Hand-authored format-0 MIDI with **running-status** Note On and Note Off, and note release velocities
3. Rendered-performance import: keyswitch commands become ordinary MIDI note events, not recoverable Studio semantic assignments
4. Truncated files, dangling note-ons, unsupported SMPTE timing, and F7 continuation rejection
5. Project persistence import/export API and the guarantee that malformed imports do not damage previously exported data

The existing writer and planner tests continue to cover same-tick MIDI priority, atomic writes, channel filters, muted regions and exact 14-bit pitch bend.

## Outstanding gates and future development

- Final macOS Swift build, tests and optimized DAWApp build must pass on this branch head before acceptance. Existing independent sampler/DSP checks remain required by the larger integration workstream.
- Real external file import into GarageBand, Logic and Cubase, plus Garritan/ARIA controller response, requires the **single consolidated Mac hardware acceptance milestone**.
- The native MIDI reader does **not** imply full live tempo-map playback. The Main DAW/Transport work must be coordinated before enabling accurate stepped or ramped tempo transport playback.
- Clip loop semantics must be defined and implemented in shared playback before any loop flattening into exported SMF can be called faithful.
- MIDI-imported notes do not regain Studio semantic map IDs; keep the original `.dawproj` for fully editable articulation workflows.
- No branch merge performed; coordinate duplicate writer from draft PR #6 during final integration.
