# Studio — Serialized Native Graph Control Milestone

**Date:** November 13, 2026
**Branch:** `architecture/studio-independence`
**Scope:** experimental Core Audio backend, not production AVAudioEngine.

## Delivered

- Introduced `StudioGraphControlGate`, a reentrant control-domain mutex. **The render callback never acquires this lock**. The gate serializes hardware start/stop, callback drain/restart, synchronous graph topology commits, bounded parameter queue production, immediate MIDI submission, scheduled MIDI production, buffer resizing, core metronome updates, and non-render state accessors.
- Prepared Audio Units remain configured outside the gate, so an asynchronous instrument instantiation does not hold a lock or stop hardware while suspended. The final `installInstrument` and `installEffect` steps enter the serialized, callback-drained control boundary.
- Instrument preparation now captures the hardware render-buffer size under the gate and passes it as an explicit preparation parameter. If buffer configuration changes before the prepared instrument is committed, installation fails with a retryable configuration error rather than attaching an AU configured for a stale slice size.
- Audio-clip scheduling now performs its transport check and clip mutation under control serialization and drains active output callbacks, even when the transport is paused. Metronome click-list updates now drain callbacks rather than racing the audio renderer.
- Added control-gate regression tests for nested calls, 4,000 concurrent control-side updates, and release of ownership after throwing.
- The prior off-graph Audio Unit preparation milestone CI `43545360206` passed. This milestone's final CI must be checked separately.

## Important safety boundaries

The new gate is deliberately **not a render-thread lock**. It removes overlapping control-side stop/start and installation operations, but it cannot make a plugin's own render callback or the inherited effect signal path real-time-safe.

Not yet exclusive: asynchronous offline bounce overlaps the control graph and hardware state, and the current protocol has synchronous void setters that cannot propagate a failure from hardware-drain fallback. Those need a separate bounce/graph lease and explicit failure reporting. Other work includes sample-rate/device changes, plugin prepare ordering when multiple loads target the same track, audio clip streaming lifetime, AUv3 state migration, and long-running orchestra stress testing.

Topology changes continue to stop and restart the experimental hardware output. This milestone is about **serialized control ownership**, not an epoch-based live snapshot swap. The render snapshot membership and parameter mailbox from previous milestones are retained.

No change to the default production AVAudioEngine path, persisted project formats, Garritan libraries, or other branches. No merge authorized or performed.

## Next

Build explicit offline-bounce and graph-operation exclusivity, then introduce prepared immutable AU/topology snapshots with safe retirement and nonblocking live publication. Validate all changes in macOS CI and a consolidated real Mac acceptance run before switching the default backend.
