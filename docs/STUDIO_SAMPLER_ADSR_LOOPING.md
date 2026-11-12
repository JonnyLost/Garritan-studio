# Studio Sampler — ADSR & Sustain Loop milestone

Implemented on `feature/studio-sampler-native`. This feature builds on the
original native sample engine without relying on third-party instruments,
plugins, DSP libraries or external sound libraries.

## ADSR playback

- Four native engine controls: attack, decay and release in seconds; sustain
  as a linear gain level [0,1].
- Each note snapshots the current instrument envelope on note-on, so live
  changes don't unexpectedly change notes already playing.
- Attack and release have a minimum 64-sample anti-click ramp; decay and
  sustain handle zero-duration and zero-level settings.
- A note-off initiates release from the current envelope level. All-notes-off
  and MIDI CC120/123 use the same bounded release path.
- Settings are queued through Studio's existing serialized MIDI-producer
  queue and read inside the render callback. No allocation, file I/O, locks
  or logging are introduced on the audio thread.
- The instrument front panel includes responsive Attack, Decay, Sustain and
  Release controls for every native instrument presentation. Values are
  saved into optional fields in the version-1 sampler patch, so existing
  projects continue to decode.

## Sustain loops

- Per-zone optional source-frame loop start and exclusive end positions.
- The source recording plays normally at the beginning; while a note is
  held it repeats the selected interval.
- Optional crossfade at the wrap boundary blends the outgoing loop tail
  with the incoming loop start. It skips already crossfaded input frames
  on wrap, avoiding double playback of the same segment.
- After note-off, looping ceases, and the source audio tail plays under the
  ADSR release envelope. If there aren't enough source frames after the
  loop end, the sample naturally ends early.
- The mapping editor offers a **Sustain Loop** tab beside the existing
  keyboard/velocity zone editor. Turn looping on, edit start/end/crossfade
  in sample frames, then choose **Apply Mapping**. These are nondestructive
  settings; the original recording is never modified.
- Sample duration metadata is read off the main UI thread and the loop
  settings are checked against the actual decoded sample length before
  the new audio node is attached.
- Auto Map preserves loop markers attached to the same source file paths.

## Known limits and next work

- Loop markers are currently numerical source-frame controls plus a simple
  range bar, not yet a zoomable waveform and draggable handle editor.
- ADSR is per instrument, not per zone.
- Loop mode is sustain-forward; reverse/ping-pong, release-sample triggers,
  playback while sustaining the post-loop tail and additional loop modes
  will be separate milestones.
- Voice stealing can still abruptly replace the oldest voice when polyphony
  is exceeded. A later refinement should implement de-clicking on steals.
- Long sample sets remain RAM-backed, with the existing bounded frame count.
- Disk streaming, loop point auto-detection, zero-crossing alignment,
  offline loop analysis and attack/release sample pairing remain future work.
- Native sampler support for the alternative Core Audio backend is not yet
  implemented.
- Do not present this as Mac listening-verified until the automated macOS
  build and a consolidated hardware test both pass.

## Automated tests

- C++ standalone tests (AddressSanitizer + UndefinedBehaviorSanitizer):
  invalid ADSR values, attack/decay/sustain/release behavior, invalid loop
  bounds, sustained audio after the original sample ends, release into the
  source tail, and loop-boundary continuity.
- Swift DAWCore tests: persistence of envelope and zone loop metadata,
  backwards-compatible optional patch decoding, source-file frame-boundary
  rejection, and offline audio-engine rendering of sustained/released loops.
- macOS GitHub CI: `swift build`, `swift test --parallel`, and
  `swift build -c release --product DAWApp`.

Keep user Mac testing for the next larger integrated composing milestone.
