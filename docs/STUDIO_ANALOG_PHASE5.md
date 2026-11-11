# Studio Analog — Step 5, expressive MIDI performance

## New engine features

- Original C++ DSP now receives full MIDI channel numbers (0–15) for notes,
  controllers and pitch bend. Note ownership is per pitch *and channel*.
- Sustain pedal (CC64): key-off is deferred while the pedal is down; lifting
  the pedal releases all unheld voices on that channel.
- Same-pitch overlapping notes: one note-off releases one oldest held voice,
  rather than stopping all unisons. A stolen note cannot be erroneously
  released by an old note-off after it has been reassigned.
- Pitch bend supports the MIDI 14-bit range, with a configurable bend width
  (0–24 semitones, initially ±2).
- CC1 modulation wheel can control LFO vibrato or filter cutoff, with a
  per-track depth and destination selection.
- Velocity remains mapped to amplitude and may additionally affect the
  filter cutoff via the \`Velocity → Filter\` panel control.
- Voice allocation prefers idle voices, then released voices, then oldest
  held voices. CC120 stops sound; CC123 releases all held notes for that
  channel. Global panic also resets pedals, pitch wheel and modulation wheel.
- The MIDI timeline can accept a 0–65,535 **frame offset relative to the next
  synth render call**. Events are executed on their exact target sample,
  preserving insertion order for events sharing a frame and carrying pending
  offsets across buffer boundaries. The queue remains bounded and lock-free
  with one serialized producer.

## Integration

Studio's \`TrackInstrument\` routes live and sequenced note messages, CC1,
CC64, CC120/123, and pitch wheel events to the new native MIDI API.
The Swift bridge serializes producers outside the audio callback.

A **Performance MIDI** section in the Analog panel now provides Pitch Bend
Range, Mod Wheel destination (Vibrato or Filter), Mod Wheel depth, and
Velocity to Filter. Their values are saved in per-track StudioAnalogPatch
settings and restored when Studio reopens the project.

## Timing limitation (important)

The engine now executes pre-scheduled events accurately within its own
render buffers. **This is not yet end-to-end sample-accurate DAW playback.**
The current legacy PlaybackEngine forwards due track events from an
asynchronous MIDI worker, often with an "immediate" sample offset. A caller
which submits later than the intended render callback cannot backdate the
event. The next timing milestone is a transport-to-render-clock pre-scheduler,
using a shared audio timebase and bounded lookahead, with seek and loop
cancellation. It must not block the audio thread.

The first 16-channel C++ controller implementation is not MIDI Polyphonic
Expression (MPE); CC and bend are shared by all voices on a channel.
Voice stealing may still click and the first modular graph switch remains
buffer-aligned rather than crossfaded.

## Checks

Run \`swift test\` and \`swift build -c release --product DAWApp\` in CI.
C++ standalone sanitizer tests cover sample-offset events across render
blocks, deferred sustain note-off, malformed MIDI rejection and graph
continuity. XCTest adds tuning/frequency, same-pitch note overlaps, bridge
channel/controller calls, parameter persistence and native AVAudioEngine
offline rendering.

Keep feature/studio-analog and draft PR #2 isolated. No merge without user
approval. Save the on-Mac hardware test until after the MIDI and patch
management milestones are consolidated.
