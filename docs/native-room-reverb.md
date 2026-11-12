# Garritan Studio — Native Room Reverb (prototype)

Status: **4 native room profiles available through the Orchestral Stage acoustic-space picker; Apple mediumHall remains the default. A macOS Debug build and regression tests passed for this implementation on 11 November 2026. In-app Audio Unit listening and device-level checks remain pending.**

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

The acoustic-space picker is present in compact and expanded Orchestral Stage
views. Select **Apple Medium Hall (Legacy)** or one of four original native
venue-inspired profiles. The room ID persists as an optional property of
DAWState, so older projects default to the established Apple reverb. Native
profile changes reuse the same 16-line network and retain its tail; switching
between Apple and native graphs is intentionally disabled during transport
playback/recording. Individual tracks retain existing stage sends/depth.

## Acoustic reference catalog

A separate [127-room research index](./acoustic-room-reference-index.md) and [machine-readable source catalog](./acoustic-room-reference-catalog.json) record worldwide scoring stages, live rooms, concert halls, opera houses, echo chambers and cathedrals. Of these, 55 have published/reported reverberation values; most are **not playable presets** and still require acoustic calibration. Room names are research inspirations, not official licensed emulations.

## Preliminary profile targets

| Profile | Bass RT60 | Mid RT60 | High RT60 | Status |
|---|---:|---:|---:|---|
| Abbey Road Studio One inspired | 2.4 s | 2.2 s | 2.1 s | Initial artistic estimates |
| MGM/Sony Scoring Stage inspired | 1.35 s | 1.15 s | 1.05 s | Initial artistic estimates |
| Synchron Stage Vienna inspired | 1.8 s | 1.7 s | 1.55 s | Initial artistic estimates |
| Boston Symphony Hall inspired | 2.2 s | 1.9 s | 1.7 s | Initial artistic estimates |

All four profiles are selectable using the new parameterized in-process Audio
Unit. The shared legacy Apple hall remains the default.

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
- The UI forbids Apple-to-native engine switching during playback or
  recording. Selecting another *native* profile changes AU parameters and
  precomputed delay gains without creating or resetting the delay lines.
  Room switching is currently available only while the transport is stopped.
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
1. Initial macOS CI (prior prototype) succeeded: https://github.com/JonnyLost/Garritan-studio/actions/runs/43142554778. Updated scoring-room selection: macOS Debug build and regression tests passed on https://github.com/JonnyLost/Garritan-studio/actions/runs/43147911064; optimized Release build status should be checked separately.
2. Test that the in-process Audio Unit instantiates at 44.1/48/96 kHz,
   and that switching during engine idle preserves existing dry audio.
3. Evaluate CPU, memory, mono compatibility, denormal/NaN handling, and
   sustained orchestral playback under real-time constraints.
4. Measure decay curves (RT60 by octave, EDT, C80, interaural correlation)
   and retune against licensed or published references.
5. Venue-selection UI and optional project-state field are implemented;
   next implement per-track early reflections, microphone position, smooth
   transitions between the Apple and native effects, and a proper impulse
   measurement/calibration harness.

No convolution is used at runtime. Published room impulse measurements can
still inform offline calibration without becoming runtime dependencies.
