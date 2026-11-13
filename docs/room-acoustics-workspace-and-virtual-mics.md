# Studio — Room Acoustics Bottom Workspace & Virtual Microphones

**Branch:** `feature/stage-acoustics-sync`  
**Status:** Feature implementations committed; macOS build, regression and audio-device listening should be verified for the current HEAD before integration.

## Workspace organization

Studio now exposes **Rooms** in the same resizable bottom-workspace navigation as
Stage, Instruments, Channel, Articulations, Piano Roll and Mixer.

- **Stage:** orchestra seating, individual instrument pan, front/back zone,
  per-track reverb send and overall visual placement.
- **Rooms > Room Library:** choose the original **Apple Medium Hall**, four
  original algorithmic *inspired* presets, or the current custom room.
- **Rooms > Room Designer:** edit the existing room size, wall/floor/ceiling
  materials, treatment and six-band predicted decay. Applying a new room still
  requires the transport stopped.
- **Rooms > Acoustic Controls:** overall shared reverb and the new virtual
  stereo-microphone listener controls. Stage movement remains in Stage.
  
The workspace uses the existing **ProjectViewModel**, **AudioEngine**, profile IDs,
per-track early-reflection processors and single late FDN. There is no duplicated
plugin or alternative signal path. The bottom editor remains resizable, collapsible,
and accessible through Studio's existing workspace navigation.

The Stage and Rooms surfaces are **sibling bottom editors**, not simultaneously
stacked full-size screens. A future responsive stage+room split view could keep
both visible together on larger displays.

## Virtual microphone v1

A new `StudioVirtualMicrophoneSettings` project property stores a
listener perspective plus early-reflection stereo width. Older projects
default to Conductor/Close, 100% width, retaining previous native audio.

| Perspective | Native direct multiplier | Additional reflection delay | Early reflection gain |
|---|---:|---:|---:|
| Conductor / Close | 1.00 | 0 ms | 1.00 |
| Main Stereo Pair | 0.86 | 3.5 ms | 1.08 |
| Audience / Distant | 0.70 | 8 ms | 1.16 |

Stereo width adjusts both the lateral reflection timing and the
mid/side gain difference of those early reflections. The setting supports
0–150%, with 100% retaining prior native behavior.

The direct multiplier applies only when the native reverb is selected.
The original Apple Medium Hall remains unaffected by stored microphone
controls; switching back to it restores original direct balance.
All AU parameter settings are handled without reconstructing the graph.
Delay/storage resources are prepared before audio rendering.

**Acoustic limitation:** this is a deliberately controlled perceptual
listening-perspective model, **not** a physical microphone array, ray
tracer, directional pickup pattern, or calibrated binaural/hall model.
It does not add independent direct sound travel-time differences,
or actual microphone-specific preamp/tonal characteristics.
Virtual mic controls are a starting point for a more realistic system.

## Calibration verification

The earlier multi-room calibration job
[43403946837](https://github.com/JonnyLost/Garritan-studio/actions/runs/43403946837)
ended without a completed macOS build/calibration. Do not interpret
it as an acoustic measurement success.

The current workflow builds all targets, runs Swift regression tests,
builds the optimized app, and then runs the **eight-profile** synthetic
room study (four factory, three contrasting custom rooms and default
holdout). It uploads a JSON artifact and summarizes available T20 bands
and errors. The test-room design source is
`StudioAcousticCalibrationScenario.swift`, with methodology in
[the cross-room study](./native-room-cross-room-calibration.md).

Even successful CI cannot establish perceived realism, CPU use on a
portable Mac, or device-level AU behavior. Those require the planned
single consolidated MacBook listening/performance milestone.

## Next engineering steps

1. Review the eight-profile T20 report and calibrate six-band feedback
   only when multiple scenarios and the default holdout improve.
2. Add more realistic listener and instrument geometry; keep runtime
   memory bounded and avoid allocation in callbacks.
3. Add coefficient smoothing and glitch-free room transitions.
4. Expand appropriately licensed acoustic references and validate
   recording/microphone scenarios, with attribution.
