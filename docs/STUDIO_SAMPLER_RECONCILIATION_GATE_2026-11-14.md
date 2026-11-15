# Studio native Sampler reconciliation gate — 2026-11-14

## Scope and immutable baseline

The shared staging baseline is `integration/studio-safe-consolidation-2026-11-14`, commit `513804f9097b37eb440a6969d76c2476c9fae9d7`.
The Sampler development source is `feature/studio-sampler-native`. This document is an audit and implementation handoff, **not** a claim that the new Sampler changes have already been merged or tested. Keep original branches unchanged; do not merge into `main` or `garritan-integration` before integrated Mac acceptance.

GitHub compare (baseline...source) reported **diverged: source ahead 211, behind 505**. Do **not** merge this entire historic source branch or accept blanket `ours`/`theirs` conflict resolution. The shared staging branch already includes a native Sampler implementation and recent project-save integrity, pro MIDI, Rooms/mics, Ostinato, and audio export.

## Existing shared Sampler baseline to retain

- Native `StudioSamplerDSP` and `StudioSharedPCM` targets; `StudioSamplerInstrument`, `StudioSamplerPatch`, sample library, mapping, disk worker/chunk reader, waveform analysis, loop finding.
- Existing Sampler editor, mapping/loop views and track integration.
- Source-specific current AppState save/autosave and Audio Unit snapshot logic, project persistence, professional MIDI planner/articulations, instrument routing and export menu.
- Existing room and virtual microphone returns, stage and Ostinato workspace.

## New Sampler capabilities needing selective port

Observed in the source-branch compare but absent from the shared staging tree:
- `DAWCore/Sources/DAWCore/Audio/StudioSamplerInstrumentFactory.swift`
- `DAWCore/Sources/DAWCore/Audio/StudioSamplerInstrumentPackage.swift`
- `DAWCore/Sources/DAWCore/Audio/StudioSamplerFactoryProcessor.swift`
- `DAWCore/Sources/DAWCore/Audio/StudioSamplerFactoryRecovery.swift`
- `DAWCore/Sources/DAWCore/Audio/StudioSamplerFactoryStarterLibrary.swift`
- `DAWUI/Sources/DAWUI/Views/StudioSamplerFactoryView.swift`
- `DAWUI/Sources/DAWUI/Views/StudioSamplerLibraryBrowser.swift`
- Accompanying tests for instrument factory/packages/orchestral patches and source documentation.

The source also changes shared `StudioSamplerInstrument.swift`, `StudioSamplerMappingBuilder.swift`, `StudioSamplerPatch.swift`, `StudioSamplerSampleLibrary.swift`, `StudioSamplerDSP.{h,cpp}`, `PlaybackEngine.swift`, `ProjectViewModel.swift`, `MainWindowView.swift`, `TrackHeaderView.swift`, `ProjectPersistence.swift`, `Package.swift`, and sampler views. **These must be reconciled API-by-API**, not wholesale copied. Source `DAWApp/Resources/Info.plist` changes also require review and are not automatically imported.

## Port order

1. Review factory and package model dependencies and import narrowly scoped new files; adapt to current `StudioSamplerPatch` and shared PCM APIs. Add direct package round-trip and missing-sample recovery tests.
2. Port factory processing/starter library and instrument-builder workflow, preserving offline, bounded memory allocation and render-thread safety. Add generated-patch validation, deterministic mapping, orchestral velocity/round-robin/legato/release tests.
3. Reconcile source Sampler DSP structures and mapping enhancements with current render graph **one feature at a time**, preserving all recent dry/reverb/mic routing. Verify note-off/voice theft/underruns at 44.1 and 48 kHz.
4. Connect factory and library UI into current instrument picker/track type without replacing the Main Window's Rooms/Ostinato, MIDI articulation editing, audio export or Save/Discard/Cancel flows.
5. Validate project save/reopen with native Sampler package references, missing files, edited sample paths and Audio Unit state, plus legacy GPO project compatibility.

## Hard acceptance gates (on a new candidate, not this audit branch)

- `swift package resolve`
- `swift build`
- `swift test --parallel`
- `swift build -c release --product DAWApp`
- Source-appropriate native sampler standalone DSP tests and stream-stress checks.
- Cross-feature preservation: professional MIDI articulation playback/seek/loop, note and CC editing, recorded audio, grouped stem/stereo/mono export, synth/granular playback, Rooms and stage/mic routing, Ostinato, project revision-aware save and reopening.
- Manual macOS smoke test: build a small instrument from samples; verify pitch, velocity, RR, loop, release, legato where supported; create instrument track; play, stop, seek and loop; add hall send; export stem; save/relaunch/reopen; confirm no missing sample or stuck voice.
- Confirm fresh integrated GitHub Actions results on the **final merged candidate head**. Past green branch-only tests are insufficient.

## Current verification status

Repository branch comparisons and baseline file inspection completed remotely on 2026-11-14. No cross-branch sampler code merge, full macOS build, automated suite execution, physical audio verification or final candidate CI is claimed by this audit. This gate intentionally protects the consolidated milestone while defining the next code-port step.
