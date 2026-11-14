# Garritan Studio — Native Room Reverb (prototype)

Status: **Four native room profiles remain selectable in the Orchestral Stage. A new optional per-track early-reflection sidechain and offline impulse analyzer are committed but macOS CI for these changes is still pending. Apple mediumHall remains the default; in-app listening and device-level checks remain outstanding.**

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
playback/recording. Individual tracks retain the existing stage sends/depth; the new early path adds position-dependent acoustics when native processing is selected.

## Position-aware early reflections (experimental)

When a native room is enabled, each instrument receives a lazily created,
wet-only NativeStageEarlyReflectionAudioUnit. It derives distinct left/right
reflection timing and gain from the persisted stage pan and L0–L5 zone, then
feeds a **separate early-reflection return**. The existing 16-delay FDN
produces one shared late tail. Global early taps are disabled in the late
Audio Unit to avoid doubling them.

The original dry track output and hall-send paths are preserved. Native
early-reflection nodes do not get instantiated at all until a native room is
selected; selecting the Apple reverb mutes the new early return. Track mute,
solo, volume and wet trim affect both wet branches. Track deletion detaches
the additional nodes. This is a perceptual spatial model, **not** measured
ray-traced geometry or an exact replica of a named venue.

Known limitations: stage movements cause discrete rather than smoothed
delay updates, microphone-position controls are not implemented, and
switching between Apple and native graphs still stops/restarts AVAudioEngine
when the transport is idle. Real-world Mac audio-device verification is
required before shipping this as the default.

## Offline acoustic measurement

Run `swift run -c release RoomAcousticCalibration --seconds 5` on macOS.
The executable renders each of the four rooms using the same early + late
architecture, analyzes approximate 125/500/2000 Hz octave bands, and emits
JSON with EDT, T20, T30 and wet-only C80. It computes proposed retuning
inputs but does **not automatically rewrite** the curated profiles.

CI runs the same command and uploads `native-room-calibration.json` as a
workflow artifact after Debug build, regression tests and Release build.
The current macOS workflow is at
https://github.com/JonnyLost/Garritan-studio/actions/runs/43201035469.

The analyzer uses backward Schroeder energy integration and linear decay fits
but its biquad filters are only approximations to octave-band filters; finite
tail integration is not noise-floor-compensated. This is **not an ISO 3382
conformance claim**. Room decay targets remain literature-based; real
room impulse measurements and listener-position data would be needed to
validate any claim of matching the actual venue.

Useful methodology:
- https://acousticstoday.org/wp-content/uploads/2019/03/The-Art-of-Concert-Hall-Acoustics-Current-Trends-and-Questions-in-Research-and-Design-Kelsey-A.-Hochgraf.pdf
- https://docs.jmrp.io/phonometry/buildings/rooms/room-acoustics/

## Custom Acoustic Room Designer

The [Acoustic Room Designer](./acoustic-room-designer.md) is available within
the Orchestral Stage inspector. It predicts T60 in six octave bands from
dimension, material, and wall treatment and applies a fifth, project-persisted
custom room slot to the existing native FDN. The four historic factory rooms
continue using their previous three-band damping. No convolution or external
reverb plug-in is used.

Material absorption coefficients are indicative; estimated decay and
dimension-derived early reflections are not certified room measurements.
The designer preview is always available, but Apply requires stopped transport.

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
- Stage pan/depth now also controls dedicated per-track early reflections in
  native mode; microphone perspective is not yet modeled.

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
5. Venue selection, per-track ER and offline impulse analysis are implemented;
   next review the CI calibration report, retune measured FDN decay, add
   microphone perspective and smooth transition between Apple/native effects.

No convolution is used at runtime. Published room impulse measurements can
still inform offline calibration without becoming runtime dependencies.
