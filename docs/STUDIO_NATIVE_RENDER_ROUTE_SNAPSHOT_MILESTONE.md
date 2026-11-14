# Studio — Stable Native Render-Route Snapshot Milestone

**Date:** November 13, 2026
**Repository:** `JonnyLost/Garritan-studio`
**Branch:** `architecture/studio-independence`
**Scope:** experimental Core Audio `RenderGraph` only; production AVAudioEngine, Garritan/ARIA and project files unchanged.

## Delivered

- Converted the experimental `TrackNode` routing record to a stable reference object whose instrument/effect references, preallocated buffers and render-owned track parameters stay associated with the same track identity.
- Introduced an immutable `RenderSnapshot` of sorted route membership and a monotonically increasing generation. Snapshot construction and replacement occur only from existing drained control paths after creating/removing tracks or inserting/replacing/unloading Audio Units.
- The audio render loop now visits `renderSnapshot.routes` instead of enumerating the mutable `tracks` dictionary on every callback. MIDI lookup remains in the existing dictionary; topology edits still require hardware drain to avoid concurrent modification.
- Mixing commands from the preceding milestone update existing track objects rather than changing route membership. Volume/pan/mute adjustments therefore do not rebuild the snapshot. Buffer resizes update preallocated buffers on stable track references under drain without changing route membership.
- Added tests for empty graph, deterministic membership, duplicate creation, remove/no-op remove, generation tracking, unchanged route membership for parameters and buffer resizing. These tests do not require hardware.

## What this does and does not establish

The **route membership is immutable between quiescent publications**, but a `TrackNode` deliberately contains mutable render-owned parameters and plugin resources. This is *not yet* a fully immutable processing graph, nor a lock-free live topology replacement.

Topology operations still invoke `AudioOutputUnitStop` and restart the experimental hardware output. The callback cannot safely reclaim AU instances while executing a render block, so plugin lifetime and full snapshot retirement will need a single serialized control executor and explicit quiescence/epoch protocol. The existing async plugin loader suspends while output is stopped and currently relies on serialized callers; reentrant operations remain a known risk.

The experimental effect path, immediate MIDI scheduling, shared metronome state, device-switch behavior, large-orchestra performance, and AUv3 source ownership remain to be validated. The render callback still touches Swift references, and hard real-time guarantees are **not** established by this milestone.

## Acceptance

1. Verify macOS debug/release builds and Swift tests on the final branch commit in GitHub Actions.
2. Keep the native backend opt-in until consolidated real-Mac playback, device transitions, and Garritan/ARIA testing.
3. Follow up with true off-thread graph preparation, single-owner control serialization, and safe snapshot handoff/reclamation that need not stop/start hardware.

No merges or changes to other development branches.
