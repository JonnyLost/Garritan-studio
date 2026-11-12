# Garritan Studio — Native Room Reverb (prototype)

Status: **implemented in DAWCore, opt-in; macOS Audio Unit build and listening validation pending**.

## What exists

- StudioRoomAcousticProfile.swift: Codable, editable, venue-*inspired* parameters.
- NativeRoomReverbProcessor.swift: original, wet-only 16-delay feedback network
  (orthogonal Walsh-Hadamard feedback, 250 Hz / 2.5 kHz damping bands),
  with stereo sparse early-reflection taps.
- NativeRoomReverbAudioUnit.swift: in-process Audio Unit wrapper.
- AudioEngine.setNativeConcertHallReverbEnabled(_:): opt-in switch for the
  existing shared hall send/return. The tested Apple mediumHall reverb
  remains the default. A failed engine restart attempts to restore the old
  connection and restart it.
- NativeRoomReverbProcessorTests.swift: profile JSON, wet-only impulse,
  cross-buffer determinism, invalid values, decay and stereo checks.

The opt-in API is currently a developer-facing integration point, **not a
user-facing UI setting**. No existing projects or their stage-depth values
are modified. The new profile does not get enabled on startup.

## Preliminary profile targets

| Profile | Bass RT60 | Mid RT60 | High RT60 | Status |
|---|---:|---:|---:|---|
| Abbey Road Studio One inspired | 2.4 s | 2.2 s | 2.1 s | Initial artistic estimates |
| Synchron Stage Vienna inspired | 1.8 s | 1.7 s | 1.55 s | Initial artistic estimates |
| Boston Symphony Hall inspired | 2.2 s | 1.9 s | 1.7 s | Initial artistic estimates |

Only the **Abbey Road One-inspired** profile is loaded by the first Audio
Unit. The other two are serialized profiles for follow-up integration; they
are not yet selectable in the app.

Published room values inform general decay targets; we **did not measure**
the rooms' impulse responses or calibrate these presets against recordings.
The early-reflection taps and octave-dependent targets are designed,
not recovered from real IRs. These are not authenticated venue replicas.

Selected research references:
- https://www.abbeyroad.com/studio/studio-one
- https://www.vsl.co.at/manuals/mir-roompacks/roompack6
- https://www.bso.org/symphony-hall/about/history
- Beranek, "Concert Hall Acoustics—2008", J. Audio Eng. Soc. 56(7/8)

## DSP/operating constraints

- Mono sum drives one shared 16-delay network; stereo decorrelation comes
  from early-reflection patterns and opposite late network projections.
- Each delay line stores about 30–98 ms of Float32 audio. At 48 kHz the
  combined 16 delay lines use roughly 194 KB and the two early buffers
  add roughly 30 KB, excluding allocator/AU overhead. This is a structural
  estimate, **not measured DAW memory consumption**.
- No memory allocation or disk I/O is requested inside the DSP render loop.
  The native Audio Unit constructs its processor during
  allocateRenderResources, not inside internalRenderBlock.
- Only stereo, noninterleaved Float32 is supported at this stage.
- Swapping the reverb while playback is ongoing stops and restarts the audio
  engine; production UI should forbid this until a glitch-free switch exists.
- Individual instrument stage depth **currently controls send amount
  and dry attenuation only**. This version does not generate position-specific
  reflections or model microphone placement.

## Verification and next work

The isolated pure-Swift processor/tests were compiled and run in a small
Linux Swift 5.9-compatible package: **5 tests passed**. A three-second
48 kHz impulse render showed a finite, decaying stereo output and no initial
dry sound. This does **not** establish sound-quality equivalence, macOS
build health, or macOS Audio Unit instantiation safety.

Before making this reverb a default:
1. Build the complete DAW on macOS and run DAWCoreTests.
2. Test that the in-process Audio Unit instantiates at 44.1/48/96 kHz,
   and that switching during engine idle preserves existing dry audio.
3. Evaluate CPU, memory, mono compatibility, denormal/NaN handling, and
   sustained orchestral playback under real-time constraints.
4. Measure decay curves (RT60 by octave, EDT, C80, interaural correlation)
   and retune against licensed or published references.
5. Add venue selection UI and project state after safe engine integration;
   then implement per-track early reflections, microphone position, and
   smooth room-profile transitions.

No convolution is used at runtime. Published room impulse measurements can
still inform offline calibration without becoming runtime dependencies.
