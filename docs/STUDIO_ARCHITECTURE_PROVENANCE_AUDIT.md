# Studio architecture and provenance register

Date: 2026-11-13
Branch: `architecture/studio-independence`
Baseline: `integration/studio-complete-mac-test`
Status: code-boundary migration underway; broader authorship, assets and licensing review still incomplete.

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

## Expanded source inspection: persistence and cloud boundary

Inspected on the architecture branch:

- `DAWCore/Sources/DAWCore/Persistence/ProjectPersistence.swift`: `ProjectFileManager` is a Foundation-based actor. `projectExtension = "dawproj"`; package contains `project.json`, `Audio Files`, and `Plugin States`. The JSON envelope contains `version`, `project`, `audioFileManifest`, and `pluginStates`. The save path stages a replacement and retains the prior package until promotion; existing plugin states are read from the previous package. **Do not alter these field names or paths during branding work.**
- `DAWCore/Sources/DAWCore/Auth/SupabaseAuthService.swift`: the sole directly inspected source importing `Supabase`. Its settings keys are `com.musio.supabase.url` and `com.musio.supabase.anonkey`. These are *persisted preference keys* and must not be renamed without a migration. Auth is optional when unconfigured; the service reports missing credentials and returns without a client.
- `DAWCore/Sources/DAWCore/AI/DAWChatService.swift`: optional remote assistant uses a Supabase Edge Function HTTP proxy if configured, or a direct Anthropic API key; its AI prompt used inherited Musio product wording, updated to Studio in commit `d6eed127da54f51e788fafbdbd5509a6983b1b4b`. This file does not itself import the Supabase SDK.
- `Package.swift`: `DAWCore` currently depends on the Supabase package. A safe extraction requires checking all references to `SupabaseAuthService`, `AuthUser`, `AuthProvider`, `AuthError`, and `AppleSignInHelper` in application and UI sources, then moving only the service behind a dedicated optional module with compatible API access.

### Compatibility inventory (verified examples)

| Identifier | Purpose | Decision |
| --- | --- | --- |
| `com.musio.create.project` | Exported project UTType | Retain until project-open migration is tested |
| `.dawproj` | Project package extension | Retain |
| `project.json` | Project package manifest | Retain |
| `Audio Files`, `Plugin States` | Project package folders | Retain |
| `com.musio.supabase.url`, `com.musio.supabase.anonkey` | Existing authentication preferences | Retain until explicit migration |
| `MusioCreate` | SwiftPM package name | Retain until independent build/CI verification |
| `DAWApp` | Executable target | Retain for current build command |

### Next implementation gate

1. Enumerate callers of auth types in `DAWUI` and `DAWApp`, plus any other `import Supabase` sources.
2. Establish an optional auth target boundary with no auth dependency in real-time audio, transport, or persistence; retain existing public API behavior.
3. Confirm macOS CI build and tests before removing the SDK from `DAWCore`.
4. Do not remove cloud/AI features merely because Studio is designed to operate offline; keep them optional unless the product owner chooses otherwise.

**Verification status:** source inspection and GitHub commits only; no macOS build or runtime test executed in this checkpoint. This is not a full-repository license or provenance audit.

## November 13 implementation — current branch state (supersedes earlier baseline graph)

The initial graph above describes the **integration baseline**, not the branch
after the changes below. The active architecture branch now has:

- `DAWApp -> DAWCore, DAWUI, VST3Bridge, StudioIdentity`
- `DAWUI -> DAWCore, StudioAI, StudioCloudAuth, StudioIdentity`
- `StudioAI -> DAWCore` (HTTP/API-backed optional AI work; no Core-to-AI edge)
- `StudioCloudAuth -> Supabase SDK` (optional account sign-in)
- `DAWCore -> DAWRealtime + four Studio native DSP targets`
- `VST3Bridge -> VST3BridgeCpp`

Relevant commits:
- `a0007d45`: move `SupabaseAuthService` to `StudioCloudAuth`; three UI import updates
- `16362511`: add shared `StudioIdentity`, remove inherited sign-in artwork from the view, update visible app plist strings; preserve bundle/project identifiers; add identity tests
- `a58ca3d4`: add legacy .dawproj/standalone JSON round-trip tests and macOS architecture checks
- `1062a514`: move eight AI-service files to `StudioAI`; seven UI import updates; keep shared Project and Data helper extensions in DAWCore
- `99ec7caa`: prevent placeholder account deletion from falsely claiming remote data removal

### Scope of source-level cross-reference scan

The original 73 Swift files in `DAWCore/Sources/DAWCore` and 44 Swift
files in `DAWUI/Sources/DAWUI` were scanned for authentication references.
Only the auth service imported the Supabase SDK; three UI files referenced its
types. All 64 non-AI Core Swift files were also scanned for AI type usage;
none referenced the moved AI declarations. Seven UI files were updated for
the AI module boundary. 25 Swift test files were checked for AI references;
none needed target dependency migration.

These are **symbol/text cross-reference checks**, not a full semantic review
of the repository or independent ownership verification.

### Preserved on-disk identifiers

- `com.musio.create.project` (project UTType)
- `com.musio.create` (historical app bundle ID)
- `com.musio.supabase.url` and `com.musio.supabase.anonkey` (existing preferences)
- `MusioCreate/Recordings` (legacy Application Support recording fallback)
- `.dawproj`, `project.json`, `Audio Files`, `Plugin States`
- SwiftPM package name `MusioCreate`, executable `DAWApp`

The native product-facing name is provisionally `Studio`. Inherited identifiers
remain only where compatibility or migration scope requires them.

### Asset and redistribution items to investigate

The repository currently includes `MusioAppIcon.svg`,
`MusioLogoMark.svg`, `DAWApp/Resources/MusioLogo.svg`,
`DAWApp/Resources/musio_logo.svg`, multiple app icons, and a tracked
`DAWApp_arm64` executable (approximately 16 MB). The sign-in screen no
longer loads the inherited logo, but assets have **not** been deleted,
verified as independently authored, or cleared for redistribution.

The `VST3BridgeCpp` C++ source explicitly describes the host as a **stub**;
the Steinberg SDK is not vendored in the inspected tree. Do not claim
working VST3 hosting or derive licensing conclusions from its comments.
The repository also includes two Supabase Edge Function source files for
optional AI proxies, and the AI services can make HTTP requests when used.

The historical README claimed MIT, while no separate LICENSE or NOTICE file
was present in the inspected Git tree. This is a **documentation and
provenance gap**, not proof of infringement or proof of unrestricted rights.

### Remaining independence gates

1. Achieve a complete passing macOS CI run **after** the AI module extraction,
   including debug/release builds and regression tests. Earlier commit
   `a58ca3d4` passed the debug build, architecture checker and Swift tests;
   its later release/calibration stages were cancelled by a newer push.
2. Verify existing Audio Unit/ARIA instruments and project loading on a Mac at
   the consolidated integration milestone.
3. Make cloud authentication an optional **build-time** application feature;
   a default full-app build still resolves Supabase even though DAWCore does not.
4. Characterize transport and audio clock ownership before altering render
   scheduling; no audio graph implementation changed in this branch.
5. Audit original-source attribution, license scope, icons, presets, bundled
   binaries and `VST3Bridge` provenance before removing historical assets.
6. Revisit the SwiftPM package name, bundle identifier and recording paths only
   through a tested compatibility migration.
7. Review any future account-deletion backend separately; do not pretend a
   sign-out deletes remote data.

No branch merges have been authorized or performed. Studio remains able to
build as the existing `DAWApp` target; real-time hardware verification and
an independently owned replacement for all historical source are **not yet
established**.
