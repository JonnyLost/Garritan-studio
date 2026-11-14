# Studio native audio/MIDI boundary — Milestone 1

**Date:** November 13, 2026  
**Repository:** `JonnyLost/Garritan-studio`  
**Branch:** `architecture/studio-independence`  
**Baseline:** Existing default AVAudioEngine playback route remains unchanged.

## Purpose

Establish a Studio-owned, testable musical clock conversion contract and
remove avoidable real-time render-thread work from the **experimental** Core
Audio backend. This is a contained first step toward independently maintained
audio/MIDI infrastructure, not a claim that the whole engine has been replaced.

## Implemented

1. `StudioMIDIClockMath.swift`: pure beat/sample timing conversion used in
   `PlaybackEngine` (playback start, conversion back to beats, MIDI clip
   scheduling) and Core Audio render sample-window arithmetic. It preserves
   the historical truncation-toward-zero behavior for valid values, handles
   44.1/48/96 kHz, and guards against invalid/nonfinite tempo, beat, and
   sample-rate inputs and Int64 overflow.
2. `CoreAudioBackend.render`: removed render-thread console output, string
   interpolation, logging timers and debug-count work. The audio callback
   continues scheduling MIDI and rendering the same graph.
3. `AudioClipRenderer.render`: moved stereo working-buffer allocation to
   backend initialization (bounded to 65,536 frames, 512 KiB). The callback
   does not resize the buffer or print on read failure; unexpected oversized
   buffers are silent rather than allocating. No file-format, mixer or
   clip-scheduling APIs changed.
4. Renamed two internal DispatchQueue labels beginning with `com.musio`
   to `studio.midi.*`. These names are debugging labels, **not** application
   bundle identifiers or persisted project keys.
5. `StudioMIDIClockMathTests` covers musical timing at three sample rates,
   tempo changes, negative pre-roll, invalid clock values and sample-buffer
   overflow boundaries.

## Current paths and ownership (observed source)

| Component | Current use |
| --- | --- |
| `PlaybackEngine` | Active legacy AVAudioEngine playback, MIDI worker and AU routing |
| `MIDIPlaybackWindow` | Pure MIDI scheduling eligibility at seek/buffer boundaries |
| `CoreAudioBackend` | Experimental opt-in native backend; not the default |
| `MIDIScheduler` / `MIDIEventRingBuffer` | Experimental backend's scheduled MIDI path |
| `DAWRealtime` | Atomic capture/meter/sample-clock handoff for legacy backend |
| `StudioMIDIClockMath` | Original, Foundation-only timing conversion logic |

The current Core Audio selector remains behind the existing preference
`useCoreAudioBackend`, which defaults false. The legacy playback and
Garritan/ARIA routing path was **not** deleted or rewritten here.

## Explicitly unaddressed risks

- **Direct disk I/O remains inside the experimental render callback.**
  `AudioClipRenderer.render` still invokes `ExtAudioFileRead`, which may
  block on disk/format conversion. Removing allocations/logging does not make
  this backend fully real-time safe. Next step: a bounded producer/consumer
  clip streamer with disk decoding on a worker and clean underrun policy.
- The `RingBuffer<T>` uses hand-written head/tail fields and
  `OSMemoryBarrier`; this must be replaced or proven with real C11 atomic
  semantics before declaring the experimental SPSC path safe.
- `CoreAudioBackend` has render/shared-state synchronization and graph
  lifetime risks. Do not enable it by default or promise low-latency AU
  stability before hardware stress testing.
- The hybrid backend's timer still reads transport state across concurrency
  domains. See `docs/MIDI_SCHEDULING_STABILITY_2026-11-10.md`.
- An older `MIDISequencer` implementation also exists. Determine whether
  any production code still instantiates it before replacing or deleting it.
- Original-source provenance for inherited audio/MIDI code still needs a
  proper authorship/license review. Original timing helpers do not establish
  ownership of the rest of the audio engine.

## Verification

GitHub Actions runs local-first and opt-in cloud macOS builds, Swift tests,
Release compilation and room calibration on each branch push. Treat this
milestone as **unverified until CI passes on its final commit**. Existing
hardware/audio, MIDI seek/stuck-note and AU/GPO5 acceptance tests are still
required as one consolidated Mac milestone.

## Future milestones

1. Replace direct callback disk reads with an original streaming worker using
   a preallocated FIFO and underrun counters.
2. Replace the experimental MIDI ring's unsafe hand-written synchronization
   with proven atomic SPSC storage; add ordering/overflow tests.
3. Establish a single immutable render-clock snapshot and cross-backend
   transport ownership, removing UI actor reads from callback paths.
4. Verify Native Studio backend and legacy regression equivalence on real
   hardware before considering an opt-in-to-default transition.

**No branch merges, project format migrations, or DSP engine replacements
were performed in this milestone.**
