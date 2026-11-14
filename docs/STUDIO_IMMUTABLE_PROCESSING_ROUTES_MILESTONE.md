# Garritan Studio — Immutable Per-Generation Processing Routes

**Branch:** `architecture/studio-independence`  
**Date:** November 13, 2026  
**Scope:** experimental native Core Audio `RenderGraph`; production `AVAudioEngine` remains untouched.

## Implemented

The prior atomic route exchange published immutable *membership*, but each route pointed at a mutable `TrackNode` holding its Audio Unit, effects and scratch. Replacing a plug-in or resizing a buffer therefore modified storage reachable by older snapshots.

This milestone introduces:
- `ProcessingResources`: a fully initialized, immutable strong-reference bundle for each route generation, containing the AVAudioUnit owner, its AudioUnit/render block, ordered effect owners and separately allocated stereo scratch storage.
- `TrackControls`: an independent identity for gain, pan and mute, still updated by the sole render/control consumer using the previously established SPSC parameter queue. Existing channels retain mixer control values when their processing generation changes.
- `RenderRoute`: captures a track ID, `TrackControls` and the **specific** `ProcessingResources` instance at snapshot publication. The callback and scheduled MIDI scheduler resolve resources only through this captured route, not through the control-side mutable track dictionary.
- Copy-on-write processing replacement for instrument insertion, effect insertion/removal, instrument unload and buffer resizing. Each replacement constructs a new resources object and scratch buffers before swapping the `TrackNode.processing` control reference, then publishes a new atomic snapshot generation. Older snapshots retain their original object and its Audio Unit/effect lifetime.
- Regression tests for distinct per-track ownership, identity stability across mixer parameter changes, and a new resource identity/snapshot generation on buffer resizing. Updated previous tests to expect new generations when scratch changes.

## Safety boundary

This is an **immutable resource ownership and retirement milestone**, not permission to hot-swap loaded plugins without draining callbacks. Two generations may still reference the *same* underlying Audio Unit or effect object while a routing edit is in progress. Those non-reentrant devices are protected by the backend's existing hardware stop/drain path. Track creation/removal is live only for empty routes.

Current render-owned `TrackControls` are shared across snapshots by design, and solo mutation still requires an output drain. The plugin effect signal path remains under validation. The callback does not take the control lock or release retired AU owners.

The existing audio backend protocol returns raw AudioUnit references for UI interaction, which should not be mutated during an export or live topology transition without additional coordination. Complete AU state cloning, off-thread preparation of *entire effect chains*, and a safe fade/swap protocol for independent plugin instances are future milestones.

## Acceptance

Verify macOS CI build and DAWCore tests on the final commit. Keep native Core Audio opt-in until consolidated Mac audio hardware/ARIA stress testing. No other branch changes and no merge.
