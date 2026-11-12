# Studio Sampler — Polyphonic Voice Stability & Streaming Foundation

Development branch: `feature/studio-sampler-native`. This milestone
preserves ARIA, Studio Analog, the existing AVAudioEngine graph, all saved
sampler patches, and the original native C++ DSP. It adds no commercial
software, proprietary SDK or third-party sampler dependency.

## Completed voice-stability improvements

- **Individual overlapping MIDI note lifetimes.** A fixed-size, eight-entry
  note-on registry per MIDI channel and pitch replaces the old one-entry
  tracking. Every trigger receives a unique ID, shared by all its CC1
  crossfade voices.
- **Deterministic note-off matching.** Repeated note-ons of the same pitch
  are retired in first-in/first-out order. Only voices corresponding to
  the matched trigger enter release. The original velocity, articulation
  and round-robin selection drive that trigger's release sample.
- **Panic safety.** CC120, CC123 and the all-notes-off command clear all
  held note entries and never start release-trigger samples. Unmatched
  and duplicate note-offs are ignored.
- **Bounded overload behavior.** The per-key stack has eight slots;
  when exhausted the oldest held trigger is released to admit a new one.
  No maps, dynamic arrays, locks or I/O are introduced on the audio
  callback.
- **De-click voice stealing.** At voice capacity, an already releasing
  voice is preferred for recycling; otherwise the oldest active voice
  is selected. Its prior sample position and amplitude continue through
  a fixed, preallocated 64-frame fade-out while the replacement voice
  follows its own attack envelope.
- **No graph changes.** Audio output, per-track routing, stage depth and
  Concert Hall send paths stay intact.

### Resource footprint

- Original 32 active voices per instrument (user-configured range 1–64).
- Fixed-size eight-entry held-note pool for each of 16 MIDI channels and
  128 notes.
- Preallocated retirement tail pool proportional to active voice capacity.
- No unbounded work queues or heap allocation in the C++ render callback.

## First disk-streaming component: bounded native PCM page reader

`StudioSamplerDiskChunkReader` uses Apple's `AVAudioFile` to open native
mono/stereo audio files for random-access reading on a dedicated worker.
It reads a requested page of at most **16,384 source frames**, supplies
linear Float32 stereo PCM, handles short final pages, and rejects invalid
seeks and oversize requests. The reader does **not** decode the entire
recording at initialization.

`StudioSamplerStreamBudget` defines initial MacBook-first budgets:

- 4,096 source frames per page
- Four pages (16,384 frames) of read-ahead per active voice
- About 250 ms of sample attack in memory, capped to 32,768 frames
- 4 MiB maximum read-ahead PCM storage for 32 simultaneous stereo voices;
  8 MiB at the absolute 64-voice ceiling (excluding the separate attack
  cache, track graph and audio buffers)

These are budget values for the upcoming real-time integration, **not a
claim that playback currently operates from disk**.

### Critical pending streaming integration

The current `StudioSamplerInstrument` **still decodes complete recordings
into bounded RAM buffers before attaching the engine**. Its existing
10-million-frame per-file / 32-million-frame-per-instrument limits remain
in force.

The next task is connecting the new worker-owned random-access reader
to a lock-free, generation-checked DSP read-ahead buffer. That will require:

1. Per-voice stream IDs and preallocated producer/consumer PCM pages
2. A background worker that services read/seek requests and prefetches
   through note-off, transposition, and sustain-loop wraparound
3. Atomic page ownership so a page is never rewritten during audio reads
4. Safe underrun handling (no render-thread blocking, decoding or disk I/O)
5. Fallback to in-memory samples for small recordings and unsupported cases
6. Automated performance, I/O stress, multi-voice, loop/seek and regression
   tests before enabling streaming by default

Do not silently substitute virtual memory mapping: on-demand page faults
could block the real-time audio callback, violating our latency goals.

## Automated verification

- `Tests/StudioSamplerDSPStandalone/main.cpp`: real-time sanitizer tests
  for overlapping notes, matched note-offs, release recordings, voice
  stealing continuity, bounded re-trigger bursts and panic.
- `Tests/DAWCoreTests/StudioSamplerTrackIntegrationTests.swift`:
  random-access page accuracy, file seeking, right-channel preservation,
  short EOF reads, and fixed memory bounds.
- `studio-sampler.yml`: Ubuntu ASan/UBSan tests, macOS Swift build,
  whole-suite regression tests and optimized release app build.

Mac hardware listening remains a **later consolidated milestone**.
