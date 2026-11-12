# Studio Sampler — Round-Robin Takes & Release-Trigger Recordings

Branch: `feature/studio-sampler-native`. Uses Studio's own native
C++ renderer, original Swift models and the existing track audio graph.

## What is implemented

- Every sampler zone has two new *optional* fields:
  `roundRobinIndex` (0–7, displayed as take 1–8) and
  `isReleaseTrigger` (default false).
- The DSP alternates between available, recorded variations when repeating a
  note in the same MIDI channel, articulation and velocity band.
- Each CC1 crossfade layer plays *one* chosen RR variation, not all takes.
  If a band lacks that variation, the first mapped take for that band is
  used. Playback remains bounded by the current native voice allocator.
- Note-on selects a sample according to pitch, velocity, articulation and RR.
  Its note and original velocity/articulation/variation are retained in
  fixed-size render-thread state.
- A matched note-off releases the attack/sustain voices and triggers exactly
  one mapped one-shot release recording. A release recording matching the
  original RR take is preferred. Unmatched/duplicate note-offs do not
  retrigger a release sample.
- The release plays once from its trimmed start to end and uses its own short
  de-click attack. It never enters a sustain loop.
- MIDI panic/all-notes-off and channel CC120/123 **do not spawn new release
  recordings**. They clear held-note state and release existing voices.
- Incoming keyswitches still do not sound as notes, and a keyswitch change
  after note-on does not change the recorded articulation used by that
  note's release.
- The waveform/key mapping editor exposes **Round-robin take (1–8)** and
  **Release sample** controls on every sample zone.
- The instrument front panel displays release sample counts, available RR
  takes and per-zone role. No new synthesis plug-in is needed.

## Suggested filename conventions

Import multiple audio files with names such as:

- `Violin_C4_pp_rr1.wav`
- `Violin_C4_pp_rr2.wav`
- `Violin_C4_ff_rr1.wav`
- `Violin_C4_ff_rr2.wav`
- `Violin_C4_release_rr1.wav`
- `Violin_C4_release_rr2.wav`

The native mapping builder recognizes `rr1`–`rr8`, `take1`–`take8`,
`alt1`–`alt8`, and separate `release`, `rel` or `noteoff` filename
tokens. Matching RR takes in the same dynamic band are given the *same*
key and velocity range, while release recordings are mapped independently.
Unknown names still use the older sequential-root and velocity mapping
fallback. These are filename hints, not pitch or articulation analysis.

## Performance and safety

The audio callback never allocates memory, locks, reads files or changes
sample buffers. RR counters and note-off bookkeeping have fixed dimensions.
Imported PCM samples are still bounded, RAM-backed and immutable during
rendering. Existing instrument patches decode with RR take 1 and no
release-trigger flag.

## Limitations before final sampler milestone

- Polyphonic retriggers of the exact same note/channel currently share one
  held-note slot: a note-off releases matching sounding attack voices and
  fires one release recording using the newest note's metadata. A full
  overlapping-note voice stack is planned.
- Sample release playback assumes a matching recorded file; Studio cannot
  invent a realistic release sound without one.
- Sample switching is at audio block boundaries rather than sample-accurate
  MIDI timestamps.
- Oldest-voice stealing may still cut a voice when polyphony is exhausted.
- Disk streaming, release velocity/CC customization, automatic articulation
  detection and round-robin reset/randomization modes are future stages.

## Regression verification

The DSP sanitizer suite tests variation alternation, note-off release tails,
invalid RR/loop combinations and panic behavior. Swift tests cover filename
hints, grouped dynamic layers, persistence, invalid mappings and actual
offline release playback. The dedicated GitHub macOS workflow compiles,
tests and builds the release app.

Do not mark Mac live performance as listening-verified until the planned
consolidated hardware milestone.
