# Studio (working name)

Studio is a native macOS music-production environment under active development.
The aim is a capable, efficient, self-sufficient DAW for composition, orchestration,
MIDI, recording, synthesis, sampling, mixing and scoring to picture—built to run
well on a MacBook and work without a subscription or online service.

The application is **not yet a validated production release**. It retains
some historical components while independent Studio implementations are developed.

## Build and run

- macOS 14 or later
- Xcode 15 or later, Swift 5.9 or later

```bash
swift build
swift test
swift run DAWApp
```

The executable target remains `DAWApp` so existing development commands work.
The SwiftPM package retains its historical `MusioCreate` identifier pending
a separately verified migration. Product-facing windows and app metadata now say
**Studio**.

## Architecture

| Module | Purpose |
| --- | --- |
| `DAWApp` | Native macOS application entry point and project commands |
| `DAWUI` | SwiftUI composing, editing and mixing interface |
| `DAWCore` | Audio/MIDI, transport, project persistence and instrument integration |
| `DAWRealtime` | Low-level real-time callback primitives |
| `StudioAnalogDSP`, `StudioFMDSP`, `StudioWavetableDSP`, `StudioSamplerDSP` | Native instrument DSP |
| `StudioIdentity` | Shared display name and compatibility identifiers |
| `StudioAI` | Optional online AI/composition services |
| `StudioCloudAuth` | Optional cloud authentication using Supabase |
| `VST3Bridge` | Compatibility bridge; the C++ VST3 host is currently a stub |
| `RoomAcousticCalibration` | Offline room-response diagnostics |

The **DAWCore target has no dependency on the Supabase SDK or StudioAI module**.
Optional online features are still included in the default UI build, so a
full SwiftPM dependency resolution may still download Supabase. Removing that
full-build dependency is a separate future packaging task. Native music
creation does not require a signed-in account.

External AI services may require credentials and can have provider charges;
they are not necessary for ordinary Studio composition.

## Project compatibility

Keep existing `.dawproj` project packages, `project.json`, legacy audio
folders, plugin state, and Audio Unit/ARIA instrument loading compatible.

The file-type identifier `com.musio.create.project`, historical bundle
identifier `com.musio.create`, and legacy preference/recording paths have
been **deliberately retained**. These are technical compatibility identifiers,
not the product's current name. Do not change them without migration tests.

The `architecture/studio-independence` branch has regression checks covering
project envelopes, older standalone JSON project opening, app metadata and
module dependency boundaries. Its macOS CI runs builds and tests.

## Provenance and licensing review

Studio evolved from an earlier codebase called *Musio Create*; the transition
to independently developed components is incremental. Historical naming and
image assets remain in the repository for investigation, not endorsement.

The previous README stated `MIT`, but the inspected repository tree has no
standalone LICENSE or third-party NOTICE file. That statement alone does not
establish ownership or redistribution rights to every inherited source,
sample, logo or bundled asset. Audit and retain required attribution before
distribution. No Git history has been rewritten or older code deleted en masse.

See [Studio architecture and provenance register](docs/STUDIO_ARCHITECTURE_PROVENANCE_AUDIT.md)
for boundaries, compatibility rules, unresolved risks and next steps.
