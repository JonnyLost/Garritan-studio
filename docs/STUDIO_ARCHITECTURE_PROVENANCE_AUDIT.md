# Studio architecture and provenance register

Date: 2026-11-13
Branch: `architecture/studio-independence`
Baseline: `integration/studio-complete-mac-test`
Status: initial source inspection, not a complete authorship or licensing determination.

## Goals and safety rules

- Studio is the product-facing working name; do not rename the repository, build targets, or project identifiers as an incidental cleanup.
- Preserve existing project files, Garritan/ARIA and Audio Unit compatibility, instrument and reverb routing, and all native DSP.
- No destructive rewrites, merges, or changes to other development branches.
- Treat authorship and licenses as **unverified** until corroborated by commit history, external origin, and dependency notices.

## Confirmed manifest dependency graph (integration baseline)

- DAWApp -> DAWCore, DAWUI, VST3Bridge
- DAWUI -> DAWCore
- DAWCore -> DAWRealtime, StudioAnalogDSP, StudioFMDSP, StudioWavetableDSP, StudioSamplerDSP, Supabase
- VST3Bridge -> VST3BridgeCpp
- RoomAcousticCalibration -> DAWCore
- DAWCoreTests -> DAWCore, DAWRealtime
- StudioAnalogDSPTests, StudioFMDSPTests, StudioWavetableDSPTests -> respective DSP modules

This is a package-level graph, not proof of runtime coupling or source ownership.

## Source-level findings sampled

| Source | Observed fact | Classification | Migration action |
| --- | --- | --- | --- |
| Package.swift | Package name is MusioCreate; Supabase is a direct DAWCore dependency | Legacy naming; external dependency | Audit usages before moving cloud services out of core |
| DAWApp/Sources/DAWApp/DAWApp.swift | Project UTType uses com.musio.create.project; app window/process name Garritan Studio | Legacy compatibility ID; product-facing naming | Introduce neutral identity constants with backwards-compatible UTType and file-opening tests |
| DAWCore/Sources/DAWCore/Audio/AudioEngine.swift | AVAudioEngine orchestral stage and native Concert Hall paths coexist | Mixed legacy and newer work, provenance unverified | Preserve graph; characterize behavior before refactor |
| DAWCore/Sources/DAWCore/Audio/PlaybackEngine.swift | Legacy MIDI queue identifier, asynchronous playback and native synth scheduling coexist | Mixed implementation, provenance unverified | Identify scheduling ownership and timing contracts |
| README.md (main) | Describes Musio Create and AI-assisted workflows | Legacy documentation | Rewrite after functional audit, without deleting attribution |

## Preserve

- Existing working transport, project files, playback, instrument hosting, stage acoustics.
- Dedicated Studio DSP targets and DAWRealtime pending source-by-source provenance confirmation.
- Optional compatibility features until replacements pass regression tests.

## Investigate before replacement

1. Complete commit-by-commit provenance and original Musio Create licensing.
2. Source imports and runtime usage of Supabase; establish offline behavior.
3. VST3 SDK provenance, redistribution obligations, and usage; retain AU hosting.
4. Project serialization, extensions, UTTypes, migrations, and round-trip tests.
5. AppState, TransportState, audio/MIDI clocks, and view model coupling.
6. Assets, fonts, icons, presets, and all bundled notices.
7. Source-level dependency and license inventory on each active feature branch.

## Candidate migration sequence

1. Establish compatibility tests and stable product identity boundary (no changes to serialized IDs).
2. Separate optional network/cloud services from core runtime, after usage audit.
3. Isolate project and transport contracts; migrate one service at a time.
4. Consolidate MIDI scheduling against render clock without regressing AU playback.
5. Refactor audio engine behind tested routing interfaces.
6. Refactor UI and optional plugin compatibility; remove obsolete resources only after verification.

## Verification gates

For every implementation stage: Swift build and unit tests on macOS CI; project open/save round-trip with legacy files; native synth/sampler playback; AU/ARIA instrument loading; audio graph/reverb send; transport/recording/loop regression; offline startup. Performance and actual listening remain explicitly unverified until a consolidated Mac milestone.

## Current audit limitations

This initial register is grounded in Package.swift, README.md and sampled beginnings of DAWApp.swift, AudioEngine.swift and PlaybackEngine.swift. It does **not** establish complete source ownership, license clearance, full repository file inventory, or Mac runtime performance. Expand this register before deleting or rewriting implementations.

## Implementation checkpoint: application identity boundary

Commit `6871416e503a573d6fa5a9bdc135b83364e052c8` introduces `StudioApplicationIdentity` in `DAWApp.swift`. The process name, main window title and appearance settings heading now use the working product name **Studio**. The exported UTType continues to use `com.musio.create.project`, intentionally preserving legacy project recognition. Existing `.dawproj` paths, SwiftPM package name, executable target, preferences keys, theme names and serialized content are unchanged.

This is a narrow identity change, **not** a declaration of independent code ownership or a project-format migration. Mac build, file round-trip and launch behavior have not yet been verified. Follow-up: enumerate every persisted identifier and legacy branding occurrence before changing further labels, and add compatibility regression coverage before changing file-format metadata.
