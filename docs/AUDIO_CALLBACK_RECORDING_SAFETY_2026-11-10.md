# Garritan Studio — Task 2: Audio Callback and Recording Safety

Date: 2026-11-10  
Branch: `feature/stage-acoustics-sync`  
Related: `docs/MIDI_SCHEDULING_STABILITY_2026-11-10.md`, `docs/ALPHA1_COMPOSITION_WORKFLOW.md`

## Source changes

1. **Bounded realtime capture handoff:** new `DAWRealtime` C target with
   C11 atomic, single-producer/single-consumer stereo ring. Ring space is
   preallocated before installing a tap; input callbacks copy Float32 data
   without disk I/O, locks, heap allocations or UI dispatch.
2. **Background WAV writes:** `BufferedAudioCapture` drains on a dedicated
   serial writer queue. Microphone and V-Rack recording share this implementation.
   Recorded frame counts come from successful writer flushes. Data loss or write
   failures invalidate the take, report the error, and remove the partial WAV
   rather than returning a truncated file.
3. **UI updates:** input recording levels, waveform updates and V-Rack capture
   levels are delivered through throttled main-run-loop timers rather than
   dispatching a task for each audio buffer. Waveform history is bounded.
4. **Non-recording metering:** C11 atomic peak accumulators replace the
   render-callback main-queue dispatch in microphone, V-Rack and per-track
   meters; the UI reads them at roughly 10–20 Hz.
5. **Transport display:** master timing tap now publishes a sample position
   using an atomic scalar. UI/Combine notifications are polled at 30 Hz;
   existing MIDI callback timing and the AVAudioEngine signal path remain
   unchanged.
6. **Input monitoring race:** a delayed microphone permission response
   cannot install a monitoring tap over a recording tap, and denied permission
   is respected rather than bypassed.

## Tests and verification

- `RealtimeCaptureBufferTests` covers ring wraparound, stereo ordering,
  mono-to-stereo duplication, bounded overflow/drop accounting, peak meters,
  and sample-position atomic handoff.
- `BufferedAudioCaptureTests` writes a synthetic stereo signal to 24-bit
  WAV through the real capture worker and reads it back. This does not need
  installed sample libraries or audio hardware.
- GitHub Actions workflow: `https://github.com/JonnyLost/Garritan-studio/actions`
  builds all targets and runs unit tests on macOS. Review the latest result
  before claiming a clean build.
- **Prior known unrelated failure:** `ProjectPersistenceSafetyTests.
  testFailedFullSavePreservesPreviouslySavedProject` currently demonstrates
  that a missing audio file can be silently accepted and overwrite an older
  project. Keep this failing test; repair in Task 3 (project integrity).
- No real microphone, ARIA, Instant Orchestra, or Garritan listening tests
  have been performed in this coding pass.

## Residual limitations, not declared solved

- The master timing tap's MIDI callback still reads mutable timing state
  and invokes a Swift callback on the render thread; this requires a dedicated
  playback-clock ownership design and Mac timing regression tests. This
  task removes per-buffer *UI* tasks without altering the verified MIDI clock.
- Experimental Core Audio backend and optional diagnostic taps still need
  realtime/concurrency review; do not enable the experimental backend yet.
- The background writer uses a bounded FIFO (not infinite buffering). If the
  disk stops accepting writes for long enough, a recording is intentionally
  rejected rather than presenting an incomplete file as complete.
- Recording hardware format changes and device disconnects need on-device
  verification; these may terminate a take. Monitoring route mixer lifecycle
  is tracked in Task 3.

## Gate before calling Alpha 1 validated

1. Confirm macOS CI app build and the new ring/WAV tests.
2. Fix the independent project-save failure in Task 3.
3. During one consolidated user Mac milestone, record microphone audio and
   V-Rack output while playing GPO5/ARIA, check durations and waveforms, stop
   safely and replay the WAV, and stress stop/start at normal buffer sizes.

Do not merge this branch without explicit approval.
