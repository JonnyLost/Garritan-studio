# Studio — Native Render Clock and Transport Ownership Milestone

**Date:** November 13, 2026  
**Branch:** `architecture/studio-independence`  
**Scope:** experimental Core Audio backend only; default AVAudioEngine playback remains unchanged.

## Implemented

- `DAWRealtime` now owns a C11-atomic `DAWRenderTransport`, with separately published playing state and absolute sample position. The Core Audio render callback reads the playing flag and sample position atomically, and publishes its completed buffer position atomically. UI-facing `currentSamplePosition` / `isPlaying` accessors read the same state.
- `CoreAudioBackend` invokes `withDrainedOutput` for play, pause, seek, stop-playback, MIDI queue clear and audio-clip clearing. When the hardware output is running, the control thread stops and drains in-flight output callbacks before mutating these resources, then restarts it. If the stop call fails, it does not modify callback-owned resources. A failed restart leaves playing false.
- The existing disk-streamer prefill/seek and MIDI scheduler APIs are preserved. No project format, default audio engine, Garritan/ARIA, or sound-library compatibility changes.
- Atomic transport unit tests cover initial state, seek, pause/restart, negative preroll and concurrent clock access.

## Real-time constraints and limitations

The C11 operations are nonblocking and do not allocate in the callback. **The hardware drain is intentionally blocking, outside the callback.** Rapid seek or play transitions may briefly interrupt the experimental hardware output. For a mature low-latency engine, a later lock-free command/immutable graph-snapshot design may avoid stop/restart churn.

The experimental backend assumes **serialized calls from one control domain**. This milestone does **not** serialize arbitrary concurrent callers of CoreAudioBackend, nor does it fully protect graph mutations, live Audio Unit hosting, master-volume/meter state, metronome state, scheduling while bouncing, or preview MIDI commands. These still require deliberate ownership contracts and additional tests before enabling native backend by default.

Two atomics are not a multi-field seqlock: position and playing are independently safe to read, but a simultaneous UI read of both is not guaranteed to be a single coherent transport-generation snapshot. Rendering avoids inconsistent seek transitions by draining callbacks before changing the position.

`clearScheduledMIDIEvents()` runs only while the output callback is drained; the previous SPSC queue must never be reset concurrently. The MIDI producer remains required to be serialized as documented in the SPSC milestone.

## Verification gate

GitHub Actions needs to complete macOS debug build, Swift tests, Release build and acoustics checks on this final commit. Hardware stress/garritan sessions remain for one consolidated Mac integration test. No merge authorized or performed.

## Next milestone

Establish a full experimental backend control/graph ownership contract, including safe live graph updates and Audio Unit lifetime, plus a coherent transport generation or immutable command snapshot. Do not switch default engine until tested.
