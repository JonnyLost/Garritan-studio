# Studio — Atomic Render Route Exchange and Deferred Retirement

**Date:** November 13, 2026  
**Branch:** `architecture/studio-independence`  
**Status:** Implemented in the opt-in native Core Audio backend; final macOS CI and hardware validation required.

## Delivered

- Added `DAWRenderRouteExchange`, a standalone C11-atomic publication primitive. The render thread increments a reader count **before** loading the current opaque snapshot pointer and decrements after use. The sole control writer exchanges prepared snapshots atomically. `seq_cst` ordering ensures any callback that observed a retired pointer was admitted before that pointer can be reclaimed.
- Replaced `RenderGraph`'s directly shared Swift snapshot property with an atomically published, reference-owned `RenderSnapshot`. Snapshot objects contain generation, stable route membership, and an immutable TrackID lookup dictionary. The control thread owns every retained object and all Swift ARC releases; the callback borrows snapshots but never destroys them.
- Both audio rendering and scheduled MIDI delivery now consult an acquired snapshot, rather than walking the mutable control-side track dictionary. The bounded parameter queue also resolves tracks through the snapshot.
- **Adding an empty track is the first live-published topology operation:** preparation and snapshot publication occur under the serialized control gate without stopping the hardware output. Existing callbacks may complete their prior route list. The new empty track becomes visible to later callbacks.
- Added bounded deferred reclamation: replaced snapshot pointers are retired on the control side after all reader epochs have ended. If 48 snapshots remain awaiting reclamation, the next empty-track addition falls back to a guarded callback drain before publishing more. This is not a lock, wait, or ARC cleanup in the audio callback.
- Added C exchange tests for reader admission, pointer publication, retirement and shutdown guards, plus an empty-track creation/render concurrency regression test. Existing stable-membership snapshot tests are preserved.

## Explicit safety limits

This is a **real atomic route-membership exchange**, but **not yet a full live Audio Unit / buffer graph swap**. `TrackNode` objects are still shared across snapshots and hold mutable AU, effects, buffer pointers and gain/pan/mute values. Old and new snapshots can therefore reference the same TrackNode. Destroying or replacing those resources while an audio callback holds an old snapshot remains unsafe without additional immutable per-route ownership.

Accordingly, track **removal**, Audio Unit installation/unload, effect replacement, buffer-size changes, and transport/clip operations **retain the hardware drain boundary**. Do not remove those guards until immutable processing resources can be built separately, switched atomically, and disposed on the control side after read quiescence. Snapshot retirement itself does not make a referenced AudioUnit safe to dispose.

The control thread must remain serialized, and offline bounce must retain exclusive access to the shared graph. The exchange does not guarantee perfect hard real-time safety for the inherited AU/render code, avoid every swift reference operation inside callback, or validate third-party AU thread behavior.

## Verification and next phase

Require a passing macOS GitHub Actions build/tests for the final commit; run native hardware/ARIA stress tests only at the agreed consolidated Mac milestone. Keep the working AVAudioEngine production backend unchanged and do not merge this branch.

**Next milestone:** immutable per-route processing/resource ownership and true live removal/replacement of preprepared routes with epoch-safe retirement. Then verify effect signal routing, scheduled MIDI timing, and export fidelity on hardware.
