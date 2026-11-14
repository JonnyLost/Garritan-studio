# Studio — Professional MIDI Milestone 14: Integration Readiness and Regression

**Review date:** 2026-11-14  
**Repository:** `JonnyLost/Garritan-studio`  
**Integration readiness branch:** `feature/pro-midi-m14-integration-readiness`  
**Stack:** `feature/studio-export-engine` → `feature/pro-midi-sequencer` (draft PR #10) → `feature/pro-midi-file-export` (draft PR #11) → this branch  
**Important:** No existing branch has been merged, rebased, or replaced as part of this milestone.

## Verified starting point

Milestone 13 at commit `49f36b2db241500c41efb966f4a1daad7b031eaf` completed the macOS `Studio Professional MIDI Arrangement` GitHub Actions build, Swift regression tests, and optimized DAWApp build with a **success** result. The earlier milestone testing source was repaired after a compiler error on the MIDI track editor; the final branch head is the passing revision.

## Repository branch audit — non-merge comparison

These are **ahead/behind counts** at the time of the audit, not an indication of conflicts or compatible merge order.

| Comparison, BASE...HEAD | State | HEAD ahead | HEAD behind | Practical implication |
|---|---|---:|---:|---|
| `feature/pro-midi-sequencer` → `feature/pro-midi-file-export` | Ahead | 37 | 0 | MIDI SMF I/O and M13 polish are a clean, stacked development layer |
| `feature/studio-export-engine` → `feature/pro-midi-sequencer` | Diverged | 133 | 16 | The base export workstream advanced after the MIDI branch diverged |
| `integration/studio-complete-mac-test` → `feature/pro-midi-file-export` | Diverged | 322 | 206 | The general composing/instrument work and MIDI work are not yet one tested application |
| `feature/studio-core-midi-export` → `feature/pro-midi-file-export` | Diverged | 322 | 213 | Separate original writer PR #6 overlaps the writer already adapted and tested within draft PR #11 |

These numbers must be rechecked at integration time; other workstreams can continue developing independently. In particular, the GitHub "mergeable" flag on **stacked PR #11 into PR #10** does not prove that the same changes are conflict-free against `integration/studio-complete-mac-test`.

### Review the duplicate writer exactly once

- Draft PR #6, `feature/studio-core-midi-export`, adds the native format-1 SMF writer and an original File → Export MIDI command.
- Milestone 11 adapted that writer to `feature/pro-midi-file-export` and connected **`StudioMIDIExportPlanner`**, preserving note-off priority and opt-in rendering of user-customized articulation commands.
- **Use the integrated planner-backed writer as the desired behavior** when reconciling. Review PR #6 for any later bug fix, but do not integrate both copies of `StandardMIDIFileExporter.swift`, or accidentally replace the planner-backed version with the older direct track-loop serializer. Keep PR #6 open until the product owner authorizes final branch consolidation.

### File-level integration decisions (do not blindly overwrite)

| File / subsystem | Must preserve when reconciled |
|---|---|
| `DAWApp/Sources/DAWApp/DAWApp.swift` | Existing project menus, file dialogs and native composing track creation; **one** File → Import MIDI and **one** File → Export MIDI mode selector; no duplicate export menu |
| `DAWCore/Sources/DAWCore/Persistence/ProjectPersistence.swift` | Native `.dawproj` safety, existing JSON/export behavior, `.midi` musical default, explicit `.midiPerformance` and atomic SMF writes, validated non-destructive MIDI import |
| `DAWCore/Sources/DAWCore/Models/Track.swift` | Native synth/sampler and orchestral routing fields, per-track articulation map, MIDI channel filter, source project backward-compatible Codable |
| `DAWUI/Sources/DAWUI/ViewModels/ProjectViewModel.swift` | Instrument creation/mixer routing from primary development, note/piano-roll editing, articulation assignment history and stage expression updates |
| `DAWCore/Sources/DAWCore/Audio/PlaybackEngine.swift` | Both audio backends, native instruments, seek-state recovery from `StudioMIDISessionPlanner`, note trims, CC handling; **do not add alloc/locks or file I/O on audio render callbacks** |
| `DAWCore/Sources/DAWCore/Models/MIDIEvent.swift` | Optional `NoteData.isMuted` decoded safely from legacy saved projects; preserve articulation note IDs and note-channel semantics |
| `DAWUI/Sources/DAWUI/Views/PianoRoll/*`, `Views/Timeline/*` | Both edit surfaces, note Split/Glue/Mute and single-step Undo, CC/articulation lanes, quarter-note bar mapping in compound meter |
| `DAWCore/Sources/DAWCore/Persistence/StandardMIDIFileExporter.swift` | One writer, planner-driven MIDI events, conductor/track handling, type-1 480-PPQ SMF, validation before atomic replace |
| `Package.swift` and native DSP targets | Preserve the independent Sampler, Synth, Granular, Additive and Physical Modeling workstream build requirements |

## Concrete regression additions in this branch

`Tests/DAWCoreTests/StudioMIDIIntegrationRegressionTests.swift` covers an assembled orchestral project with MIDI and instrument tracks plus an audio track, offset/trimmed MIDI clips, authored CC11, a rendered keyswitch+controller articulation, a muted note, native synth selection, Garritan program ID, stage-depth fields, 6/8 meter and stepped conductor tempo changes.

The tests assert that:
1. Musical MIDI and Rendered Performance MIDI select the correct number of tracks and preserve instrument note pitches without producing the audio track or muted notes.
2. Rendering keyswitches does not modify or lose the Studio project, instrument identifiers, stage settings, authored MIDI event IDs, or editable articulation metadata.
3. The live MIDI session planner and musical-only export agree on note trimming, silence and CC timing for a region that starts away from bar one.
4. An invalid continuous tempo ramp fails *before* overwriting a previous valid on-disk `.mid` file.

## Automated readiness gate

`.github/workflows/studio-midi-integration-readiness.yml` runs two independent jobs on the isolated readiness branch:
1. **Read-only Git branch overlap scan** via merge-base + `git diff --name-only` + `comm`, comparing changes against the Mac integration, export engine, duplicate MIDI writer and composing track workflow branches. It does **not** run `git merge`, create a merge commit, modify branches, or claim overlapping filenames are textual conflicts. The Actions Step Summary provides a current file-by-file overlap report for the eventual integrator.
2. **macOS 15 full acceptance:** `swift package resolve`, `swift build`, `swift test --parallel` and `swift build -c release --product DAWApp`. This compiles/tests the complete code on *this branch*, **not** a nonexistent consolidated build of divergent source branches.

## Remaining release/acceptance conditions

1. Product-owner authorization before any merge into the selected common integration branch.
2. After authorization: deliberately reconcile the files above, choose the final branch order, preserve the general DAW and native instrument work, and run full macOS CI on that resulting actual integrated HEAD. Do not mark integration green based on this rehearsal branch.
3. One **consolidated on-Mac composing milestone**, not repeated micro-tests: create Instrument / Synth / Sampler / Audio tracks, hear/review Garritan and native instruments, record and edit MIDI, test CC1/11 and articulations, Split/Glue/Mute, undo, save/reopen a native project, load/re-render a performance MIDI file in a second DAW, and verify stage/reverb and track mixer routing.
4. Known intentional boundaries: looped MIDI clips are not yet flattened; non-step tempo ramps are rejected for SMF export; generic SMF cannot retain Studio-specific semantic articulation IDs; sound playback against Garritan/ARIA and cross-DAW UI have not been physically auditioned.

**Outcome target:** A decision-ready, regression-tested MIDI feature stack that can be integrated safely when authorized. This milestone does not pretend separate diverged branches have already been merged.
