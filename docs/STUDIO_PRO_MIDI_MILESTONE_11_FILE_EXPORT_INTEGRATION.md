# Garritan Studio — Professional MIDI Milestone 11
## Native Standard MIDI File Writer + Articulation-Aware File Menu Export

Date: 2026-11-14
Repository: `JonnyLost/Garritan-studio`
Development branch: `feature/pro-midi-file-export` (stacked on `feature/pro-midi-sequencer`)

### Scope and branch safety

This change is isolated on a new integration branch from the professional MIDI feature. The native format-1 Standard MIDI File writer originated on the **separate** `feature/studio-core-midi-export` workstream (draft PR #6); its independent source and tests were deliberately adapted onto this stacked branch for a working end-to-end integration. **Neither branch was merged**. Before finalizing the common integration branch, review the duplicate export implementation in PR #6 and reconcile it; do not blindly merge both copies.

### What is now connected

1. `StandardMIDIFileExporter.encode(project:mode:)` retains the existing format-1 480-PPQ conductor track, tempo/time-signature changes, separate named musical tracks, signed 14-bit pitch bend, channel messages, SysEx, end-of-track events and VLQ delta times. Musical track channel data now comes from `StudioMIDIExportPlanner.messages(for:tempo:mode:)`, preserving its note-off → state → keyswitch → musical-note precedence at the same tick.
2. `ProjectFileManager.export` keeps the existing `ExportFormat.midi` behavior as **musical-only** by default and introduces `ExportFormat.midiPerformance` for explicit instrument-dependent articulation rendering. Both modes validate the entire SMF in memory and use atomic file writes; neither modifies source project notes or dirty/save state.
3. File → **Export MIDI…** asks whether to export *Musical MIDI* (authored notes and controller data, no generated keyswitches) or *Rendered Performance MIDI* (current map translated to keyswitches, CCs, program changes and note-channel assignments), then opens a native save dialog and shows an alert on failure.
4. The planner surfaces understandable invalid-tempo, clip-range, MIDI data, and unexpanded-loop errors.

### Regression coverage

Copied forward the native writer's conductor/track, controllers, pitch bend, time signatures, channel filter, invalid-data atomic write, and tempo-ramp/loop tests from the original core export workstream. Added independent SMF byte decoding assertions for:
- default versus rendered exported file events, including keyswitch / CC / musical-note precedence at identical ticks;
- note-off before same-tick retriggers;
- both `ProjectFileManager.export` format choices round-tripped through actual on-disk SMF file bytes;
- authored semantic note IDs remain in the source Studio project rather than being destructively baked into MIDI note events.

### Deliberate limitations and remaining validation

- Standard MIDI Files are **not** Studio project files: user-defined semantic articulation IDs/maps do not survive generic SMF import. Keep the `.dawproj` to preserve editable articulations.
- Performance-mode keyswitch pitch, program, and controller meanings are instrument-specific; GPO5 Notation mappings without calibrated triggers remain silent rather than guessing. Instant Orchestra's controller-based expression remains supported.
- Unexpanded MIDI clip loops and non-step tempo ramps are rejected instead of silently exporting a different performance; complex tempo-map timing, cross-project import, and externally verified file compatibility remain follow-up work.
- No hardware/ARIA audition or third-party DAW import was performed. GitHub Actions macOS Swift build/test, Release DAWApp and standalone sampler native DSP validation must pass on the final branch head before declaring verification.
- Draft PR remains unmerged. Avoid merging or rebasing other Studio feature branches without product-owner approval.
