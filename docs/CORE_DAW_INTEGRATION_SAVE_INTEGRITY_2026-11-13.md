# Studio — Core DAW Integration & Project Integrity Milestone

Date: 2026-11-13
Base branch: `integration/studio-complete-mac-test` at `327ba05288640b123312e3f1465124965b297792`
Development branch: `feature/studio-core-project-integrity`
Status: implementation committed; review final macOS CI before integrating. No Mac hardware test or branch merge authorized.

## Live integration snapshot

Branch references were read directly from GitHub on November 13:
- Main combined Alpha baseline: `integration/studio-complete-mac-test` (`327ba052`).
- Sampler final research/development milestone: `feature/studio-sampler-native` (`e7ba0c06`), native checks succeeded. The integration baseline includes earlier sampler work, not all later factory, recovery, editing and orchestral enhancements.
- Studio Synth: `feature/studio-synth` (`dc5f7efe`). Latest synth-native job reported a failure. Earlier synth versions are integrated; newer capabilities stay owned by the Synth conversation.
- Acoustics/Orchestral Stage: `feature/stage-acoustics-sync` (`15c34e80`). Earlier stage and reverb path exists in integrated Studio; newer room-designer work is on the separate feature branch.
- Native Ostinato: `feature/ostinato-engine-v1` (`7cf57f96`). Its latest integration is pending.
- Native MIDI export: `feature/studio-core-midi-export` (`19b18690`) passed its macOS build/test workflow, but is not merged.
- Architectural independence: `architecture/studio-independence` (`416fa557`), separate concurrent initiative.

Feature branches have diverged from the combined testing branch. The branch comparison is **not** equivalent to a supported merge plan; inspect conflicts and integration validation before seeking approval. None of these branches was merged or modified by this milestone.

## Why this milestone came first

The combined application already has working foundation code for track playback, MIDI editing, Audio Unit hosting, stage sends, recording buffers, project packages and transactional Quick Save. A higher-value uncovered risk was in the **application's orchestration of saving**:

1. Save captured plugin state and project data with two arbitrary 100 ms sleeps, then silently fell back to an AppState copy if no view-model response arrived. This could miss updated Audio Unit and UI state.
2. Autosave wrote via a separate `ProjectFileManager` using a model-only provider rather than the same plugin-state snapshot.
3. A slow save always cleared the Edited flag, even if new notes were added while the file was being written; Save As also wrote an old snapshot back into the live project model.
4. New Project discarded edits without a save/discard/cancel confirmation, and Open Recent could replace an edited session directly.
5. Notifications from a previous document could update AppState after the UI swapped sessions.
6. A hosted Audio Unit preset capture failure was logged without preventing a misleading completed save.

These are **source-confirmed defects/risk paths**. They do not mean the existing project package transaction logic is broken; the new work preserves that code.

## Implemented changes

### Single document-save coordinator
- Manual Save, Save As and periodic autosave all call the same AppState `persistProject` function and the same `ProjectFileManager` actor.
- A save-in-progress gate prevents overlapping manual/automatic saves and session replacement while a disk write is outstanding.
- The active MainWindowView responds to one synchronous project snapshot request that updates workspace state, captures track/rack instrument presets and insert-effect state, and returns the exact model.
- No sleep-based snapshot waiting or stale-project fallback. If the active editor cannot provide a snapshot, saving fails visibly rather than pretending success.
- Active Audio Unit preset capture failures are collected and surfaced; no project package replacement occurs after a failed snapshot.

### Revision-aware dirty state
- A small `ProjectSaveRevision` value tracks edit and saved revisions on the main actor.
- Disk completion marks the project clean **only when** the captured revision is still current.
- Save As no longer replaces the live model with an earlier saved snapshot.
- The autosave dirty flag is cleared only after the same revision-matched successful save.
- Save-and-replace refuses to close the current project if more edits arrived during saving.

### Safer session switching
- New Project and Open Recent ask Save / Cancel / Don't Save for edited documents. A canceled file chooser or failed save leaves the prior session intact.
- Open validates the incoming project before dismantling the current one.
- ProjectID gating rejects late change notifications from a previous document.
- Failure to open or save is displayed to the composer instead of only being logged.

### Regression coverage and build workflow
- `Tests/DAWCoreTests/ProjectSaveRevisionTests.swift` covers clean/dirty transitions, successful revision acknowledgement, late edits, out-of-order completion tokens and session reset.
- The existing macOS workflow now runs for the development branch: debug build, Swift regression suite, optimized DAWApp build and offline acoustic calibration.
- GitHub Actions run information is authoritative for build/test results; do not equate compilation with hands-on DAW hardware acceptance.

## Explicit limits

- This change does not rewrite the AVAudioEngine signal path or the experimental Core Audio backend.
- It does not merge the newest sampler, synth, acoustics or ostinato branches.
- Autosave remains a complete staged project-package write; this is safe but expensive for large recorded-audio sessions. Incremental, crash-safe saves remain follow-up engineering.
- Project plugin-state capture is synchronous on the main thread; long-running or broken third-party Audio Units can still affect UI responsiveness. Improve timeouts/recovery after real-world evidence.
- Hardware interruptions, unexpected power loss during package promotion, and real ARIA preset compatibility still require the consolidated Mac testing milestone.
- Native instrument patch versions and cross-branch project format compatibility must be checked during eventual integration.

## Next prioritized integration work

1. **Validation of this save coordination milestone:** macOS CI and source review now; one hardware acceptance session later with multiple native/ARIA instruments and edits during Save.
2. **Controlled branch integration (approval required):** audit synth/sampler/acoustics differences against the integration baseline, resolve overlapping ProjectViewModel/PlaybackEngine work without overwriting feature branches, and ensure backward-compatible project decoding.
3. **Unified audio/MIDI clock:** remove remaining constant-tempo and worker/render scheduling inconsistencies; develop a tested, real-time-safe transport/tempo-map owner without switching the active AVAudioEngine backend prematurely.
4. **Professional editing and production:** instrument-slot undo/redo, audio-region editing, automation, routing and buses, offline bounce and MacBook large-session profiling.

**No merges or consolidated Mac testing were performed in this milestone.**
