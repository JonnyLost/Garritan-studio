# Studio — Professional MIDI Sequencer & Arrangement Audit

**Audit date:** 2026-11-13 (America/New_York)  
**Repository:** JonnyLost/Garritan-studio  
**Work branch:** `feature/pro-midi-sequencer`  
**Starting point:** `feature/studio-export-engine` at `bcbe7e9f9de1844af9f47f9e2190827ffeecb2c1`  
**Merge policy:** no merge without explicit product-owner authorization.

## Concurrent-development boundaries

The repository had 20 branch names at audit time. Relevant neighboring work:
- `feature/studio-track-workflow` and `feature/studio-export-engine`: main track creation, mixer, and export workflows; the export branch descends from track-workflow.
- `feature/studio-core-project-integrity`, `feature/studio-core-midi-export`: project save/undo integration and SMF export on the separate Mac-test baseline.
- `architecture/studio-independence`: audio backend, MIDI clock, and native orchestration systems with major history divergence.
- `feature/ostinato-engine-v1`: pattern generation, view-model, and lower workspace, also diverged.
- Synth, sampler, reverb, and Mac-test integration branches remain independent.

Main DAW work advanced beyond the starting commit during this milestone. Do not blindly merge or rebase: compare newest shared view-model and main-window edits first. This branch does not alter synthesis, sample playback, reverb graphs, or Core Audio scheduling.

## Inventory — existing working foundations (source-verified, not hands-on tested)

| Area | Existing implementation | Source |
| --- | --- | --- |
| Arrangement | Track lanes, clips, region visualization, playhead, horizontal scroll, zoom controls, region selection, drag/Option-copy, MIDI lane transfer, trim and split | `MainWindowView.swift`, `Timeline/TimelineView.swift`, `ProjectViewModel.swift` |
| MIDI regions | Per-clip relative beat events, notes, CC events, loop/mute fields, left/right trim preserving hidden events, MIDI split handling crossing notes | `Models/Clip.swift`, `Models/MIDIEvent.swift`, `ProjectViewModel.swift` |
| Piano roll | Two editors, note and marquee selection, pencil/erase, drag and resize, quantize, velocity lane, CC lane, note audition | `PianoRoll/TrackPianoRollView.swift`, `PianoRoll/AdvancedPianoRollView.swift` |
| Transport | Start/stop, playhead seek, MIDI recording, playback event preparation and engine scheduling | `ProjectViewModel.swift`, `Audio/PlaybackEngine.swift` |
| History | Track and clip action classes, grouped actions, undo/redo audio graph reconciliation | `ProjectViewModel.swift`, DAW undo actions |
| Shortcuts | Space/Return, undo/redo, region copy/cut/paste/duplicate, split, delete, track navigation | `Shared/KeyboardShortcuts.swift` |

These are code-level observations, not proof of polished interaction or macOS runtime performance.

## Confirmed defects and risk areas

1. **Different snap grids.** Timeline region moves and trims were hard-coded to whole beats, while piano-roll snap was adjustable. Bar mode assumed four quarter-note beats irrespective of meter. The timeline, ruler, and CC/note lanes also used numerator-only measure calculations, incorrectly locating 6/8 and 7/8 barlines.
2. **Inconsistent region selection.** The region tap ignored Shift, despite multi-selection being present in the model.
3. **History holes.** Keyboard region paste/duplicate/nudge edited project data directly rather than recording undo actions; delete could create several undo steps. Cut used the selected track's clipboard but deleted selected regions across all tracks: an unsafe multi-track edge case.
4. **Conflicting split paths.** The keyboard split implementation filtered MIDI notes by note start and could lose held notes crossing the split. The context-menu splitter already preserves the crossing note by creating two adjusted note events.
5. **Two piano-roll implementations.** These overlap in state, note editing, and controller drawing but differ in available commands; choose one authoritative editing model rather than maintain divergent behavior indefinitely.
6. **Incomplete advanced tools.** The advanced editor exposes split, glue, and mute tool choices, while parts of its canvas gesture dispatch fall through without implementation. Tool behavior must be audited before declaring these supported.
7. **Compound-meter model assumptions.** The older `TimeSignature.beatsPerBar` and `TimePosition.formatted` use integer numerator-derived bars. This milestone fixes the touched UI grids only; project-wide timing and formatting need a separate controlled review.
8. **Gesture ergonomics and audio-timing proof.** Zoom/scroll responsiveness, note preview cleanup, MIDI event jitter, loop boundary note-offs, live recording and export roundtrips require measured tests on macOS. The legacy `MIDISequencer` is deliberately not bound in `ProjectViewModel`; `PlaybackEngine` owns clip scheduling. Do not wire a second transport clock.
9. **Audio edits out of scope.** Generic audio split still has an older direct model mutation path. It must be addressed with audio-aware source offsets in the Main DAW effort, not by pretending MIDI and audio splits are interchangeable.

## Milestone 1 — code now on this branch

- Add `StudioMusicalGrid`: a shared quarter-note beat grid that calculates bar length from numerator **and** denominator, handles off/bypass, and clamps invalid timeline positions.
- Add the adjustable arrangement Snap picker (Off, Bar, Beat, 1/8, 1/16, 1/32, Triplet) and route MIDI region move/trim through it.
- Draw correct compound-meter barlines in the arrangement ruler and both piano-roll editing surfaces, including CC and velocity canvases.
- Add Shift-click region toggle without forcing a single selection.
- Route general MIDI Split to the existing note-preserving `splitMIDIClip` action.
- Make multi-region cut/copy/paste/duplicate/delete/nudge preserve multi-track source lanes where applicable, validate paste destinations before mutation, and use grouped undo actions.
- Add focused grid regression tests and isolated macOS CI workflow. **Compilation and runtime verification remain pending until the workflow completes.**

## Proposed remaining milestones

**2. Editor interaction consistency.** Unify note-operation semantics across the two piano-roll views; complete resize/multi-note drag/duplicate/paste/delete with correct snapping and undo; decide the visible behavior of split/glue/mute tools. Improve region creation at pointer location, duplication/loop handles, linked ruler/scroll position, and modifier fidelity.

**3. Orchestral expression.** Proper editable CC1/CC11/CC7/CC64, pitch bend, aftertouch where available, expression curves, multi-lane editing, keyswitch/articulation labels and chase behavior on playback seek. Preserve native synth, sampler and Garritan compatibility without commercial dependencies.

**4. Timing, regression and Mac acceptance.** Verify musical positions in 3/4, 6/8, and 7/8; record/overdub/loop/tempo seek; MIDI note-off and CC chase; piano-roll vs arrangement editing; grouped undo; project reopen; MIDI export/import; CPU/latency on MacBook. Consolidate one user-led composing milestone after automated checks.

## Acceptance rules

- Never discard MIDI notes or controllers during moves, trim, split or clipboard actions.
- One logical edit = one undo/redo step, including multi-region actions.
- Explicit feedback for incompatible track destinations; do not partially paste a selection.
- No second MIDI playback clock or real-time unsafe UI writes on the audio callback.
- Keep synthesis, sampler, reverb, export, and Main DAW branches isolated; compare branch heads before any future integration.
- A successful code audit is not a substitute for macOS build and user workflow acceptance.
