# Studio — Native Core Audio Clip Disk Streaming Milestone

**Date:** November 13, 2026  
**Repository:** `JonnyLost/Garritan-studio`  
**Branch:** `architecture/studio-independence`  
**Scope:** experimental Core Audio clip playback only; production
AVAudioEngine / Garritan / ARIA routing is unchanged.

## Goal

Replace synchronous `ExtAudioFileRead` in the experimental output render
callback with Studio-owned bounded, lock-free-at-the-callback PCM page handoff.
Only predecoded, validated pages may be mixed by the audio thread.

## Implemented

- **`DAWRealtime` C11-atomic PCM cache:** a four-slot cache (4,096 stereo
  Float32 frames/page, approximately **128 KiB per audio clip**), with
  worker-owned publishing and nonblocking callback-side read claims.
  Every cache slot includes its absolute clip-relative page index. A missing
  or stale page produces silence and increments an atomic underrun counter.
  No audio callback performs file I/O, Swift task creation, heap allocation,
  locks, waiting, console output, or Audio Unit graph mutation.
- **Background decoder:** `AudioClipRenderer` now owns one serial disk queue
  with dedicated ExtAudioFile references and one reusable PCM scratch buffer.
  It performs seeks, format conversion, and reads off the callback; normally
  polls requested pages at a bounded 10 ms cadence and fetches up to four
  ahead. Files are not read on the callback.
- **Playback start and seek:** a page for each scheduled clip is primed
  before playback is marked active, including when transport starts partway
  through a clip. Future pages are supplied by the background worker.
  The stream timer is cancelled on pause, stop and clip reset. Editing clips
  while the experimental transport is playing is refused rather than racing
  the render callback. Clear stops and drains the output unit before
  discarding old page storage.
- **Offline bounce:** `OfflineBounce` calls the explicit non-real-time
  `AudioClipRenderer.renderOffline` path, which may read disk on its worker
  queue without running I/O inside a hardware callback. Realtime playback
  and offline bounce are mutually exclusive on this experimental backend.
- **Source and test coverage:** `RealtimeCaptureBufferTests` now exercises
  PCM page supply, gain, stereo ordering, page-slot reuse, old-page rejection,
  missing-page silence, underrun counts and invalid cache sizes.
  `StudioCoreAudioClipStreamingTests` generates a WAV recording and tests
  real ExtAudioFile worker decoding, prefilled playback, seek and offline
  PCM readback without a sound device.

## Auditable memory/runtime budget

| Resource | Budget |
| --- | --- |
| Stream pages per clip | Four |
| PCM frames per page | 4,096 |
| Cache size per clip | 128 KiB |
| Shared disk-worker scratch | 32 KiB |
| Disk worker | One serial dispatch queue, 10 ms periodic wake while active |
| Callback underrun policy | Silence missing frames; atomic underrun counter |

A project with 100 simultaneous *scheduled* audio clips would allocate
approximately 12.5 MiB of PCM page storage (excluding Audio Unit libraries,
decoders and metadata). Cache memory is bounded per clip rather than growing
with song duration. More elaborate eviction/voice budgets remain future work.

## Compatibility

The .dawproj envelope, embedded Audio Files directory and all legacy
serialized identifiers are unchanged. Audio clip scheduling arguments,
output channels, gain, timing, and existing offline bounce APIs remain
compatible. Studio defaults to the AVAudioEngine backend; this new streamer
is enabled only by the existing experimental Core Audio setting.

## Important limitations

1. **Not yet hardware validated.** Automated macOS tests can validate sample
   data and builds, but do not establish glitch-free playback with large
   Garritan/ARIA sessions, device switches or real I/O.
2. **Underruns are recoverable but audible.** A delayed decoder produces
   silence for missing frames. The cache indexes pages by timeline frame,
   preventing a late page from playing at the wrong beat, but cannot
   reconstruct audio that missed its rendering deadline.
3. **Not a complete native DAW migration.** Existing Core Audio shared
   transport variables, render graph mutation, MIDI scheduler synchronization
   and Audio Unit hosting require additional ownership hardening. Do not
   switch the default engine to Core Audio on this milestone.
4. **Large clip counts need scale tests.** Each scheduled clip retains an
   ExtAudioFile handle and four pages. A later multi-track worker design
   may cap open decoders and prioritize clips near the playhead.
5. **Audible seeks need real-Mac testing.** Prefill runs synchronously on
   the non-realtime control thread. Slow disks may make transport start
   briefly wait; this is preferable to blocking the hardware callback,
   but still needs performance measurement.
6. This milestone uses the existing Apple ExtAudioFile decoder, not third-
   party audio SDKs or commercial instruments.

## Verification gates

- GitHub Actions: standard app debug build, full Swift test suite,
  optimized Release build, room calibration, and opt-in cloud compatibility.
- Consolidated Mac acceptance: audio clips spanning 4,096-frame page
  boundaries; start/stop/restart; seek into middle; disk under heavy load;
  file deletion/format errors; layered tracks; non-48-kHz devices;
  bounce from nonzero start; CPU/memory profiling and observed underruns.

Check the final branch run before declaring this complete. No branch merges
or core audio-engine defaults were changed.
