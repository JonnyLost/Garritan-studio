# Garritan Studio — Alpha 1 consolidation and protected handoff

**Candidate**: `integration/studio-alpha1-consolidated-2026-11-14`  
**Source checkpoint**: `23855a450d74e45c421002f86f7b9345f42c2d4e` (combined Sampler acceptance: macOS debug, complete Swift tests, optimized DAWApp, native C++ sanitizers and 72-zone disk stream all green).  
**Protection rule**: Candidate is separate from `main`, `garritan-integration` and the developer's normal Mac worktree. No branch deletion, reset, overwrite or force-merge.

## What is in one build now

The current Alpha 1 working tree includes native instrument selection and the four requested track types, professional piano-roll and orchestral MIDI expression/articulation/SMF export, the native Synth and Granular/Sampler bridge, the Sampler instrument builder/library/portable instrument packages, physical modeling DSP, Ostinato workspace, orchestral stage and room designer/virtual microphone routing, track/mixer sends and audio/stem export, and revision-aware project-save orchestration. It is not proof of audible behavior until the Mac acceptance session.

Concrete source evidence on the consolidated tree:
- `Tests/DAWCoreTests/StudioMIDISessionPlannerTests.swift` for MIDI seek, loop and articulation scheduling.
- `DAWCore/Sources/DAWCore/Persistence/StandardMIDIFileExporter.swift` and `DAWCore/Sources/DAWCore/Persistence/ProjectSaveRevision.swift`.
- `DAWCore/Sources/DAWCore/Audio/StudioSamplerInstrumentFactory.swift` and the Sampler factory/package tests.
- `DAWCore/Sources/DAWCore/Audio/NativeMicrophoneSpillProcessor.swift` and `DAWUI/Sources/DAWUI/Views/VRack/StudioRoomAcousticsWorkspaceView.swift`.
- Main Studio window includes the Rooms and Ostinato lower workspaces and the four track-create commands.
- New `Tools/alpha1_mac_launch.sh` opens a detached worktree and never switches or clears the original checkout.

## GitHub branch audit — no blind merges

The following branch heads are **ancestors** of the consolidated checkpoint (GitHub compare: zero source-only commits): `feature/ostinato-engine-v1`, `feature/pro-midi-file-export`, `feature/pro-midi-m14-integration-readiness`, `feature/pro-midi-sequencer`, `feature/studio-analog`, `feature/studio-export-engine`, `feature/studio-fm`, `feature/studio-physical-modeling-refinement`, `feature/studio-synth`, `feature/studio-track-workflow`, `fix/studio-unsaved-document-guard-2026-11-14`, `integration/studio-mic-merge-candidate-2026-11-14`, `integration/studio-save-integrity-2026-11-14`, `integration/studio-synth-sampler-bridge`, `garritan-integration`, `main`, both earlier November 7 backups, and the older picker-focus checkpoint. Do not replay these historical branches over Alpha 1.

Diverged branches require **tree-level** feature checks, not interpretation of `compare_commits` added-file stats as missing content:

| Independent branch | Reconciliation decision |
| --- | --- |
| `feature/stage-acoustics-sync`, `fix/studio-virtual-microphone-routing-2026-11-14` | Exact current tree files for native microphone capture/spill, room designer/workspace, calibration and channel settings already match the acoustics source. Keep later integrated dry/reverb/microphone return routing. The real merge rehearsal still has 4 and 1 conflict paths respectively. |
| `feature/studio-sampler-native` | Factory, package, library, patch, mapping, browser and recovery files match by blob hash. **Do not** replace the current `StudioSamplerInstrument.swift`: Alpha 1 has newer `StudioSharedSampleCache` / `ss_add_shared_zone_with_variation` memory-sharing integration. Historical merge shows 11 conflicts. |
| `feature/studio-core-project-integrity` | Current revision-aware save coordinator is integrated; legacy branch contains divergent main controller and project persistence changes. Historical merge rehearsal has 36 conflicts; never prefer stale main-window/MIDI functionality. |
| `feature/studio-core-midi-export` | Alpha 1 retains professional MIDI planner / articulation-aware exporter and export menu. Older branch differs from the current writer. Historical merge rehearsal has 39 conflict paths. |
| `integration/studio-complete-mac-test` | Historical shared staging baseline, with changes since superseded by the current combined feature tree. Historical merge rehearsal conflicts across audio/MIDI/UI. |
| `architecture/studio-independence` | **Not integrated as a whole**. Contains genuinely new standalone session/unsaved recovery, window close/quit guard, typed save snapshot, Core Audio graph command/route ownership, local identity/cloud boundary and additional tests. A GitHub Actions true merge rehearsal found **37 conflicting paths**, including `DAWApp.swift`, `AudioEngine.swift`, `PlaybackEngine.swift`, `ProjectPersistence.swift`, MIDI/editor views and DSP. Requires dedicated surgical forward-port, Mac CI, and hardware checks; do not overwrite the proven default AVAudioEngine/ARIA production path. |
| `windows-morning-build`, `windows-port-foundation` | Windows preview/platform work is outside the macOS Alpha 1 acceptance scope, preserved in source branches. The merge rehearsal conflicts with existing plug-in UI. |
| `integration/studio-sampler-reconciliation-audit-2026-11-14` | Corrected audit/document-only branch; does not change application behavior. |
| `integration/studio-safe-consolidation-2026-11-14` and `integration/studio-sampler-portable-packages-2026-11-14` | Alpha 1 descends from both; the latter already passed complete combined tests. |

The actual conflict counts above came from disposable `git merge --no-commit --no-ff` GitHub Actions rehearsals, with an abort/reset after every source, never from an optimistic ancestry-only assumption. A conflict is **not** evidence that a feature is missing, and a successful build is **not** proof of a Mac audio listening test.

## Release gates

1. Full macOS dependency resolution, debug build, complete Swift tests, optimized `DAWApp` on the **final Alpha 1 head**.
2. Native Sampler C++ AddressSanitizer/UndefinedBehaviorSanitizer and 72-zone/64-voice disk stress on that same head.
3. Read-only merge audit and preserved-feature file checks.
4. One hardware Mac session: no missing audio, MIDI chord/CC seek/loop and articulation, native Synth/Sampler/Granular, Rooms and virtual mics, Ostinato, track sends, stereo/mono/custom stems, Save/Discard/Cancel, save/reopen and installed Garritan/ARIA where available.
5. Do not promote to `main` or `garritan-integration` until manual acceptance and explicit authorization. Keep architecture and Windows continuation branches safe for their own reconciliation gates.

**Status**: Unified Alpha 1 test candidate, not a claim that every experimental branch is merged or that all Mac interactions have passed.

## Safe start on Mac

From the existing Studio repository, fetch this branch and launch its new `Tools/alpha1_mac_launch.sh` in an isolated worktree; alternatively use the full guided steps in `docs/STUDIO_CONSOLIDATED_MAC_ACCEPTANCE_2026-11-14.md`. Do not overwrite any valuable DAW projects.
