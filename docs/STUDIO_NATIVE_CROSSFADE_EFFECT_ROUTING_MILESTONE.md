# Studio — 25 ms Instrument Crossfade and Correct Native Effect Input Routing

**Date:** November 13, 2026  
**Repository:** `JonnyLost/Garritan-studio`  
**Development branch:** `architecture/studio-independence`  
**Scope:** experimental Core Audio backend only. The production AVAudioEngine and existing Garritan/ARIA route are unchanged.

## Delivered: short, bounded instrument crossfade

- A live instrument change retains the outgoing `ProcessingResources` and its private scratch buffer in an `InstrumentTransition`. When output is actively playing, the new patch is published atomically and the render callback generates **both instrument sources for approximately 25 ms**. A preallocated linear dry-signal crossfade blends the stereo streams across successive buffers; the **shared serial effect chain is invoked only once**, after blending.
- The outgoing instrument receives MIDI All Notes Off (CC 123 on every channel) as its fade finishes, not at its beginning. Newly scheduled MIDI is delivered only to the incoming AU. This avoids an abrupt release at the start of the fade, but does **not** migrate held-note state or an instrument's internal preset/voice state.
- A small C11-atomic progress object tracks frames rendered and lets the control thread detect fade completion without a lock. The real-time callback never allocates a transition, releases an AU, starts a timer or performs file I/O.
- One **coalesced**, low-priority control task reclaims completed transitions. It normally runs after the roughly 25 ms fade; it can retry if a track is muted/paused and ultimately forces completion to cap memory retention. Stop, pause, seek, buffer reconfiguration and export completion also retire pending transitions on a drained control path.
- An exceptional retired-snapshot backlog can still briefly drain output; the normal patch change no longer restarts the hardware engine. During a fade, the outgoing and incoming AUs require about double that single track's instrument DSP for only the fade duration.

## Delivered: real effect audio input

Previously the native graph invoked `AudioUnitRender(effect)` without supplying the previous stage through a registered AU input callback. This did not reliably feed audio into effects.

- Added `StudioEffectInputContext` and a C-compatible, nonblocking `kAudioUnitProperty_SetRenderCallback` on effect input bus 0. Raw AU effects are configured with matching stereo, non-interleaved Float32 input/output and maximum slice size **before initialization**.
- Each track scratch owner now provides two additional preallocated, nonaliased effect-input buffers. For each effect slot, the current stereo signal is copied into those input buffers; the effect's callback supplies them to the AU, which renders the next stereo stage into the track's output buffers. Later effect slots receive the prior effect's result.
- The callback supports both common AU upstream-buffer conventions: copying into supplied writable stereo output buffers or handing out stable source pointers when the AU requests zero-copy input. The render callback itself creates no temporary arrays or heap buffers.
- If an effect returns a failing OSStatus, its incoming audio is restored from the separate scratch and the effect is bypassed for that buffer rather than silently replacing its input with invalid audio.
- Note: AU configuration and effect input support vary across third-party components. Unsupported formats or missing input-callback support produce explicit load errors. This implementation is native AUv2 effect routing, not a general AUv3 render-block graph.

## Regression tests

`StudioAudioTransitionTests` covers:
- Linear crossfade start/end levels and continuity across 64-sample buffers
- Saturating, lock-free fade progress and forced completion
- Effect input sample-offset copying, silence before preparation and zero-copy source borrowing
- **An actual Apple NBandEQ Audio Unit** processing nonzero stereo PCM on macOS (skips only if the system component is unavailable)

The existing opt-in Apple sampler test now verifies that a real sampler swap retains its outgoing AU through a transition and releases it through the control reaper. Default native graph ownership and sequencing regression tests remain intact.

## Explicit remaining limits

A linear dry-signal crossfade mitigates buffer-boundary discontinuities but **is not a universal click-free or tail-preserving plug-in swap**. Plug-ins with latency, special parameter state, unusual AUv3 scheduling, multibus layouts, nonstereo formats or expensive release tails require further handling. Crossfade has no note migration, dynamic latency compensation, per-AU tail detection or automatic UI parameter state transfer.

Current effects are rendered serially and fed real PCM, but per-effect wet/dry buses, sidechain input, AUv3 effects, live latency compensation and large-orchestra audio quality have not been certified on physical hardware. A successful macOS CI compile and effect test is necessary but is not a substitute for the consolidated Mac/ARIA integration milestone.

## Acceptance and handoff

- Require the **final commit's** macOS GitHub Actions debug build, DAWCore tests, optimized build and opt-in cloud compatibility check to pass before marking this milestone CI-verified.
- The native backend remains opt-in. Preserve every parallel Studio feature branch. Do **not merge** without explicit product-owner authorization.
- Next recommended work: optional per-track AU tails/voice tracking, AUv3 effect render/resource parity and formal input/output latency compensation, followed by the agreed consolidated real-Mac composing milestone. Prioritize stable playback and measured CPU before enabling native Core Audio by default.
