# Studio Sampler — Hybrid RAM / Disk Streaming Milestone

Branch: `feature/studio-sampler-native`. This is an original macOS/Core
Audio implementation, not an Audio Unit plugin or third-party library.

## Engine behavior

- Studio Sampler automatically retains short recordings (roughly 3 seconds
  or less) as regular immutable PCM in RAM.
- Longer recordings are decoded to a short attack prefix of approximately
  250 milliseconds (bounded at 32,768 source frames per zone).
- A single serialized background disk reader for each instrument services
  requests from the real-time audio renderer. It opens source recordings
  lazily and limits live `AVAudioFile` handles to **16 per instrument**.
- The reader reuses a bounded `AVAudioPCMBuffer` and copies decoded
  Float32 PCM directly into native fixed-size playback pages.
- The DSP allocates **four** 4,096-frame stereo pages per voice *once*
  during configuration of the first streamed zone. At 32 active voices
  the maximum page memory is about **4 MiB** (at 64: **8 MiB**), exclusive
  of immutable attack PCM, sample metadata and normal DAW graph storage.
- Each streamed voice owns a generation-tagged page set. Background
  requests use an atomic, single-producer/single-consumer page-state
  handshake. The worker cannot overwrite a page being read by the
  callback. Stale requests from stolen/restarted voices are ignored.
- The callback never opens files, calls the worker, waits for a semaphore,
  sleeps, allocates, or takes locks. It only publishes page requests and
  reads fully published buffers. Pages are requested ahead of playback,
  including loop entrance pages before a sustain-loop wrap.
- On a late page the voice fades toward silence (up to 64 frames) and
  resumes smoothly when a page becomes available. A native atomic
  `streamUnderrunFrames` diagnostic reports missing PCM frame counts.
- Existing sample-rate conversion by linear interpolation, pitch
  transposition, velocity zones, CC1 layering, articulation, round robin,
  per-note release samples, ADSR envelopes, trim regions and sustain-loop
  routing remain in the same original voice engine.
- The original Audio Unit / ARIA instruments and Concert Hall track routing
  are untouched. Existing projects and RAM-resident instruments remain
  compatible.

## Example resource accounting

| Item | Approximate RAM use |
|---|---:|
| One 0.25-second stereo Float32 attack at 44.1kHz | 88 KiB |
| Four 4,096-frame stereo read-ahead pages per voice | 128 KiB |
| Page cache for 32 simultaneous voices | 4 MiB |
| Page cache for 64 simultaneous voices | 8 MiB |
| Reader scratch per open file | 128 KiB maximum |

The worker keeps no more than 16 open readers per instrument. Native C++
page arrays are allocated only if the instrument contains streamed zones,
so instruments made entirely of short samples incur none of this page
buffer cost.

## Limits and further stabilization

- This is the first real streaming integration, not a completed performance
  certification. A consolidated Mac hardware listening test remains needed.
- Some imported samples may require security-scoped bookmarks to reopen
  reliably after restarting sandboxed projects. That packaging/persistence
  work remains outstanding.
- A fresh background worker is currently created for each instrument
  containing streamed zones. A future shared I/O scheduler can reduce
  idle wakeups and improve battery usage in large orchestral templates.
- Stream loops with very long overlapping crossfades, excessive
  pitch transposition or high storage latency can miss pages.
  Transparent loop/underrun behavior still needs testing with real
  orchestral recordings on internal and external drives.
- Page reads have a bounded cache but are not sample-accurately scheduled
  to MIDI events inside each engine render block.
- Long compressed sample file decoding performance and high-polyphony
  sustained ensembles have not been benchmarked on the user's MacBook.
- Source file length is currently limited to 500 million sample frames.
  Individual RAM-based samples retain the previous 10-million-frame cap;
  resident aggregate loading retains its existing 32-million-frame cap.
- Preloading the short attacks during instrument creation remains
  synchronous; moving import and initial attack processing to a worker
  is a follow-up responsiveness task.
- When a source file is inaccessible during streaming, missing pages
  gracefully fade rather than crashing, but a visible file-error
  notification and relink workflow are still needed.

## Automated tests

The GitHub workflow `.github/workflows/studio-sampler.yml` performs:

- C++17 AddressSanitizer/UndefinedBehaviorSanitizer tests, including
  background page simulation, persistent output after attack preload,
  deliberate underruns, loop wrap and octave-up playback.
- Swift/macOS tests using real `AVAudioFile` page reads and actual
  offline `AVAudioEngine` playback of a four-second stereo recording.
- The entire DAWCore Swift regression suite, and an optimized
  `DAWApp` build.

The native DSP suite and macOS Swift test suite must pass for the
final branch SHA before this milestone is considered automated verified.
No branches have been merged without product-owner authorization.
