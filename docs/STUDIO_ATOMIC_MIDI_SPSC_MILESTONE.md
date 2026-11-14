# Studio — Atomic MIDI SPSC Queue Milestone

**Date:** November 13, 2026  
**Branch:** `architecture/studio-independence`  
**Scope:** experimental Core Audio MIDI scheduling buffer; default AVAudioEngine route unchanged.

## Implementation

The legacy generic `RingBuffer<T>` previously used ordinary Swift `head` and `tail` variables plus `OSMemoryBarrier`. This did not provide a sound cross-thread atomic ownership contract. The existing Swift payload storage now uses a small original C11-atomic `DAWSPSCCursor` from `DAWRealtime`.

- Producer checks available index with an acquire read of the consumer tail, writes the element, then publishes head with release semantics.
- Consumer checks available index with an acquire read of the producer head, reads or clears the element, then publishes tail with release semantics.
- One array slot stays vacant to distinguish empty and full. A full queue returns false and never overwrites unread events.
- The ring is allocated outside the render callback. Peek/pop on the render callback use fixed storage, no locks or blocking operations.
- `MIDIEventRingBuffer` and `MIDIScheduler` preserve their public method signatures and sample-window behavior. No project serialization or MIDI event format changes.
- New tests exercise FIFO order, queue-full rejection, wraparound, stale-event removal and a concurrent one-producer/one-consumer handoff.

## Safety constraints and remaining work

Exactly **one producer and one consumer** are allowed for each cursor. Do not call `clear()` or `reset()` while either producer or consumer is accessing the queue; existing call sites must be made quiescent at the future cross-backend transport ownership milestone. `MIDIScheduler` remains the experimental Core Audio implementation and its other shared state/render graph operations are **not** yet established as safe.

The queue assumes its events are pre-sorted by sample position; it does not sort by itself. A full ring still drops additional scheduled events; future work should surface overflow diagnostics and delivery policy rather than silently accepting dropped note-offs. The default AVAudioEngine/ARIA path is untouched.

## Verification

GitHub Actions macOS `swift build`, `swift test` and Release stages are required on the final commit; this document does not claim those checks have passed. Real hardware stress tests and seek/all-notes-off behavior remain for the consolidated Mac acceptance milestone. Do not switch engine defaults or merge this branch.
