# Studio native graph parameter handoff — milestone

Date: November 13, 2026  
Branch: `architecture/studio-independence`  
Scope: experimental native Core Audio playback. Legacy AVAudioEngine/ARIA production path and project persistence remain unchanged.

## Delivered

- New `StudioGraphParameterMailbox` uses the existing C11-atomic SPSC cursor and a preallocated 1,024-slot Swift ring (1,023 usable). Single serialized control producer submits volume, pan, mute and master-volume commands; the render callback consumes at most 128 commands at the start of a buffer, even while musical transport is paused.
- The callback applies commands in order to render-owned graph parameters before invoking MIDI, instruments and clip processing. The master gain used by the callback has a separate render-owned value, eliminating direct callback reads of the control thread's `_masterVolume` field.
- Normal gain/pan/mute/master changes no longer stop and restart hardware output. Topological graph modifications (create/remove track, AU instantiate/unload, buffer resize) still use the previous drain/restart boundary.
- When the bounded queue fills, the **control thread** drains the hardware callback, consumes all older queued commands and applies the latest command in order; it does not silently drop a control request. When the output unit is stopped, pending commands are also fully drained before direct changes. The render callback never blocks, allocates explicitly or performs hardware stop/start as part of this handoff.
- Tests cover FIFO ordering across parameter kinds, track identity, queue capacity, recovery from overflow, zero/bounded callback command budgets and repeated wraparound.
- The preceding native graph ownership milestone's CI run `43541717460` completed successfully; CI for this milestone must be verified independently.

## Important limitations

This is a **parameter command handoff foundation**, not yet an immutable graph snapshot or a complete replacement of the inherited RenderGraph. It does not guarantee glitch-free sound during Audio Unit loading or track creation and removal, because these still drain/restart the output. Swift dictionary mutations at the start of a callback also require profiling and further real-time-safety hardening; the bounded command queue itself introduces no waiting.

Commands assume **one serialized control producer and one render consumer**. A drained control thread temporarily takes consumer ownership only after `AudioOutputUnitStop` has succeeded; concurrent UI requests, async plugin instantiation and offline-bounce contention are not fully serialized by this milestone.

If a stop request fails during a full-queue fallback, the latest command cannot be applied and the void setter cannot report this; this is an explicit failure mode to resolve with a return/error contract. Effects still need a verified active signal chain; no Audio Unit hosting correctness is implied by the mailbox.

## Next development gate

Introduce immutable render-state snapshots/ownership for track topology and Audio Units, a single serialized control executor, and a safe publication/reclamation boundary. Preserve existing Garritan/ARIA support and legacy project compatibility. Validate macOS debug/release/tests and hardware playback before changing the default audio backend.
