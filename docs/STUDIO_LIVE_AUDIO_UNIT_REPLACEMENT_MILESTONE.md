# Studio — Live Audio Unit Replacement and Retired Graph Ownership

**Date:** November 13, 2026  
**Repository:** `JonnyLost/Garritan-studio`  
**Development branch:** `architecture/studio-independence`  
**Scope:** opt-in native Core Audio backend, not production `AVAudioEngine`.

## Milestone implemented

**Instruments:** A newly selected AVAudioUnit (AUv2 or AUv3 where supported by the host) is instantiated and configured outside the active graph. A control-serialized request ticket captures the selection order and hardware buffer size. After preparation, an immutable `ProcessingResources` generation is atomically published **without stopping hardware audio**. Current callbacks finish on the old generation; later callbacks render the new instrument. Superseded or canceled async loads cannot replace newer instruments, including when a track is deleted and recreated with the same ID. Previous AVAudioUnit owners remain retained in retired snapshots until readers are quiescent.

**Effects:** A new raw Audio Unit effect is prepared independently, then its `EffectLifetime` owner is committed into an immutable new route generation under the same control gate, without routine output restart. Each effect slot has its own latest-wins request ticket; unloading a pending-but-uninstalled slot cancels its load. Old effect owners stay retained by previous snapshots. The existing raw AU effect DSP chain still requires audio correctness validation; this milestone governs safe replacement/ownership, not proof of a properly connected render-input callback.

**Loaded track removal and plugin unload:** These operations now publish retired route membership/resources without routine stop/start. A previous render frame keeps its old snapshot and resources until it exits. Track buffer ownership and AVAudioUnit/effect reference lifetime are managed on the control side.

**One consistent callback generation:** Reworked scheduled MIDI delivery and track rendering to borrow one immutable snapshot for each buffer, instead of resolving an instrument for MIDI and another for audio. The native backend also claims a C11 atomic, nonblocking render admission guard **before** consuming the SPSC mixer mailbox. A reentrant callback produces silence and never processes concurrent MIDI, Audio Units, clips or metronome. The renderer and exclusive offline bounce use the same generation-pinning logic.

**Memory pressure:** The normal path is uninterrupted; an exceptional backlog of 48 unreclaimed snapshots triggers the existing guarded hardware drain to reclaim owners before publishing more. This limits memory retention on a MacBook without reference-count releases inside the audio callback.

## Tests

- Atomic route publication, reader quiescence and nonblocking exclusive render admission
- Latest-wins instrument request tokens, unload cancellation and track deletion/recreation
- Independent per-slot effect requests and cancellation of uninstalled effects
- One MIDI/audio render pass using a pinned route (hardware-free)
- Prior graph snapshot/resource ownership, buffer resizing and live track mutation tests
- Opt-in integration test that actually instantiates **two Apple AUSampler Audio Units** and replaces one with the other without attaching a hardware output: `STUDIO_RUN_AU_SWAP_TESTS=1 swift test --filter StudioRenderGraphSnapshotTests`

## Explicit limits — do not mistake safe ownership for seamless music

- A live plug-in replacement **does not preserve notes, tails or modulation state automatically**, and the transition is not yet click-free. An explicit optional crossfade/state handoff should be a separate audio-quality milestone.
- The prior effect chain and its signal connections still need verification. Shared unaffected effects are processed by one admitted hardware frame at a time, but third-party AUs may have proprietary threading constraints. The current `getInstrumentAudioUnit` protocol exposes a raw handle for client UI/parameter access, so unrelated external modifications still need their own lifetime coordination.
- Audio Unit instantiation and effect creation do not happen on the callback, but effect preparation is still synchronous on its caller's control execution context and may cause UI latency if invoked from the main thread.
- The native graph remains opt-in, with default AVAudioEngine and Garritan/ARIA production playback unchanged. Do not switch the default backend or merge before consolidated real Mac AUv2/AUv3, Garritan instrument, MIDI, realtime stress, export and device-transition tests.
- Compile/test acceptance requires a passing **final commit** GitHub Actions run. No local macOS hardware test is claimed here.

## Next development focus

Validate the effect input/render callback chain; implement a bounded, low-CPU click-preventing instrument transition (including note-off handling) and dedicated control worker for expensive AU preparation. Then perform the agreed consolidated Mac milestone, followed by native-backend promotion only if it meets playback/parity/stability criteria.

**No merge authorized or performed.**
