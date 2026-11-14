# Garritan Studio — Professional MIDI Milestone 13
## Piano-roll consistency, editable mute, split/glue and compound-meter alignment

**Date:** 2026-11-14  
**Repository:** `JonnyLost/Garritan-studio`  
**Active branch:** `feature/pro-midi-file-export`, stacked draft PR #11  
**Merge policy:** No merges until explicitly authorized.

### Source-backed audit finding

Both the clip-level Advanced Piano Roll and track-level Piano Roll already offered note selection, drag/resize, editable velocity and expression, clipboard and grouped undo, but the `MIDIEditorTool` enum advertised Split, Glue and Mute cases that the actual tool selector did not expose. Advanced eraser also called `updateClip` on *every pointer movement*, creating excess undo steps. Quantize/offset used separate implementations with problematic relative-grid rounding in offset clips and could create no-op undo entries. In 7/8, quarter-note lines were drawn from global integer positions, drifting from each 3.5-quarter bar start.

### Implemented

- Added **Split at Playhead**, **Glue**, and **Mute** commands to **both** piano-roll toolbars, with enabled state tied to note selection. Each commits one named `updateTrack` history entry, not one per event.
- Shared `StudioMIDINoteEditing.splitting` preserves the source note's left ID, velocity, pitch and duration sum; the right half receives a new ID, and the current semantic articulation assignment is copied to that ID. Edges and outside clicks are no-ops.
- Shared `gluing` joins only selected **exactly adjacent** notes on the same MIDI pitch/channel and with the same velocity, release velocity, audible mute state and semantic articulation. Gaps, overlaps and incompatible musical performance settings are left unchanged. Removed note IDs and their redundant articulation assignments are pruned together.
- New optional `NoteData.isMuted` state decodes legacy project JSON safely. Muted notes stay visible (dimmed), selectable, duplicable and undoable. The central `StudioArticulationRenderer` excludes muted notes **and** their dynamically generated keyswitches/controllers from live playback and both MIDI export modes; unchanged authored controllers and remaining notes still run.
- The Advanced Piano Roll eraser now accumulates touched IDs during a stroke and commits once at pointer-up; note hit testing is disabled while using non-select tools so the eraser reaches the canvas.
- Both piano-roll quantize/offset methods reuse shared transforms, preserve clip-relative nonnegative positions and untouched CCs, avoid no-op history entries, and use the *absolute* grid for offset regions. Advanced timing commits are now explicitly labeled. The track editor commits cross-region selections as one undoable action.
- Shared `StudioMusicalGrid.interiorQuarterBeats` and updated piano-roll rulers/grids render interior beats relative to each measure start. In 7/8, the second bar begins at beat 3.5 and its internal quarter markers lie at **4.5, 5.5 and 6.5**, not 4, 5 and 6.
- Added DAWUIWorkflow and DAWCore tests for split identity and durations, no-op edges, safe glue, conflicting articulations, copy of semantic articulation assignments, mute persistence/renderer/export behavior, controller protection, absolute-grid quantize and 7/8 grid markers.

### Explicit boundaries

- Split and Glue are *selection commands*, not independent per-pointer cursor modes. This avoids introducing a second gesture engine or conflicting resize semantics into the two existing editors.
- A MIDI note's mute state is saved in the Studio project, not a property supported by Standard MIDI Files. Muted notes are intentionally **omitted** from standard MIDI export.
- Glue intentionally refuses notes with different velocities or articulations; preserving a differing articulation by collapsing notes would be musically incorrect.
- The shared meter calculation is now used for touched rulers and note grids; full time-signature-change-aware bar numbering throughout the entire application is a separate transport/timeline integration item.
- Cross-clip Glue is intentionally unsupported to avoid silently changing arrangement clips.
- No audio engine, Core Audio callback, instrument patch, or branch merge was modified.
- The remaining Milestone 14 task is coordinated overall integration and regression across feature branches, followed by **one** consolidated hands-on composing/Mac playback test. Mac hardware has not been used in this milestone.
