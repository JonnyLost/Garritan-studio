# Studio — Exclusive Offline Bounce and Safe Export Milestone

**Date:** November 13, 2026  
**Branch:** `architecture/studio-independence`  
**Scope:** opt-in native Core Audio experimental backend; default AVAudioEngine and Garritan/ARIA production routing untouched.

## Delivered

- Added an explicit, control-serialized **export lease** to `StudioGraphControlGate`. A second export is rejected immediately; the lease stays active across every `await` in the offline renderer and is released in a `defer` on success, error or cancellation.
- Before claiming a lease, `CoreAudioBackend.bounceOffline` checks that transport is not playing and validates a positive sample interval. If the Core Audio output unit is running (even with transport paused), it **stops and drains hardware callbacks**. Pending mixer parameter commands are drained and the PCM prefetch worker is paused before offline rendering takes ownership of the existing RenderGraph, MIDI scheduler, Audio Units, metronome and clip decoder. The hardware output is restarted after export if it had been running.
- During an active lease, the serialized control boundary rejects throwing operations including `start`, `setBufferSize`, live clip scheduling and final plugin installs. The existing void control API cannot report errors, so play/stop/seek, track edits, mixer updates, MIDI submissions and metronome changes are ignored during the lease rather than modifying callback-owned resources. Future work should expose explicit error results and/or deferred updates.
- Preserved the off-graph Audio Unit preparation path; if an async instrument load completes during export, its final installation is rejected and cannot corrupt a concurrently rendered graph. `getInstrumentAudioUnit` remains a legacy escape hatch: external clients must not mutate that AU while export is active.
- Corrected a serious stereo WAV export memory-layout issue: `AudioBufferList` only physically stores one buffer inline, so the previous two-channel writer could address past its allocation. Offline bounce now uses an explicit two-buffer structure with a short-lived rebound pointer for the synchronous rendering/writing scope.
- Offline slice length is capped to the current graph buffer capacity **and** the native clip decoder's 4,096-frame scratch capacity. Huge exports no longer trap on converting an arbitrary remaining frame count to `UInt32`.
- Output file handles are closed on success, failure and cancellation. Incomplete WAV exports are removed instead of left as apparently valid files.
- Added regression tests for export-lease exclusivity, cross-thread visibility, rejected mutations and post-export release. Existing graph-control serialization and snapshot tests remain in place.

## Deliberate limitations and next gates

- The exclusive lease is a **fail-closed control boundary**, not a separate offline graph clone. Rendering offline currently consumes the same scheduled MIDI queue and may modify plug-in internal state. Before Studio offers nondestructive concurrent exports, create isolated AU/render state and MIDI events per export.
- This is *not* yet complete active UI prevention: void setters are silently skipped while exporting, and the app currently has no explicit export-state-facing error API. Expose busy/error states in the next phase.
- Hardware callbacks are stopped for the entire offline export by design. Never drive real-time playback concurrently with this shared graph.
- The first-party native graph still has an inherited, unverified effect signal path and requires real Mac integration, AU3/ARIA tests and bounce comparison before being enabled by default.
- Thread isolation of third-party Audio Units and external references returned from `getInstrumentAudioUnit` is not fully enforced by a control gate. This milestone narrows a major internal race but is not a guarantee of arbitrary plugin safety.

## Acceptance checklist

- GitHub Actions macOS debug/release builds, DAWCore tests and cloud opt-in checks on the **final commit**.
- The consolidated hardware milestone must confirm positive audio exports, canceled exports, transport/seek conflicts, rapid plugin edits, project compatibility, and no audio dropouts after output restart.
- Do not merge without explicit authorization.

## Next recommended milestone

Export-state plumbing and an isolated offline render-state plan, followed by safe immutable render-graph exchange and Audio Unit retirement. Continue prioritizing single-owner, low-latency MacBook performance.
