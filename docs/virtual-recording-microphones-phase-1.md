# Studio Virtual Recording — Phase 1: 3D Microphone Objects

**Branch:** `feature/stage-acoustics-sync`  
**Scope:** Durable foundation for virtual microphone placement and eventual
multi-source spill. **No change to audible track routing in this phase.**

## Why this is separate from the original reverb

Studio already has one native late-field reverb, position-dependent early
reflections, track pan/depth zones, and a global three-position *listening
perspective*. Those controls intentionally remain functional and unchanged.

The new recording system introduces **independent microphone capsules**.
They are persistent objects within the same designed room, not global
presets or third-party plugins. Multiple capsules can belong to a named
array. Every capsule has its own location and pickup response. Future mic
channels will capture *all participating track sources*, including spill,
before being mixed in the planned Microphone Mixer.

## Phase 1 delivered

- **3D room coordinates, in meters:** centered x is left/right,
  y=0 is the front of the stage and increases toward the back,
  z=0 is the floor and increases upward. Coordinates are bounded to
  the saved Acoustic Room Designer dimensions.
- **Five ideal polar patterns:** omnidirectional, cardioid,
  supercardioid, hypercardioid and figure-eight. The rear lobes of
  super/hypercardioid and figure-eight maintain signed acoustic pressure,
  not just a clipped positive level.
- **Four insertable templates:** single cardioid spot, coincident
  XY 90° cardioid pair, 17 cm / 110° ORTF-style cardioid pair and
  three-omni Decca Tree-style starter spacing (two meters wide with
  center capsule 75 cm farther into the room). These are intended
  as editable starting configurations, not exact microphones or claims
  of equivalent real-world recording responses.
- **Stage:** independently draggable microphone icons in the curved
  and compact orchestral layouts, distinct from instrument markers.
  The projected stage shows x/y. Height, aiming and capsule type
  are edited in the new Rooms → Microphones panel.
- **Rooms → Microphones:** add/edit/remove up to 32 persistent capsules
  per project, including those created in a grouping. Each capsule
  can be moved, aimed, tilted, renamed and assigned a polar pattern.
- **Geometry preview:** relative direct pickup, source/mic travel time,
  and distance for the first eight instrument tracks. Existing pan/zone
  values are mapped to approximate 3D stage positions consistently,
  but that mapping is not yet a calibrated physical source location.
- **Persistence:** the optional `DAWState.virtualMicrophones` field
  preserves legacy project decoding. Changing acoustic room dimensions
  reclamps stored microphones to the new legal room boundaries after
  successfully applying that room.

## Future audio-routing math

For each instrument source position `s` and microphone location `m`,
the first approximation uses:

- `distance = length(s - m)`, in meters
- `delay = distance / 343`, in seconds
- `pickup = P(dot(unit(s - m), microphoneForward))`, signed
- `directAmplitude = pickup * min(1, 1/distance) * exp(-0.003*distance)`

The last term is merely a broadband stand-in for atmospheric losses:
it is **not** an atmospheric absorption spectrum, certified prediction,
measured hall impulse response or microphone frequency response.
The model preserves phase sign for rear-lobe polar response.
Near-field distance is capped at a one-meter reference to avoid
gain singularities; this should be revisited with source directivity
and realistic close-miking as the mic DSP is developed.

The **geometry is calculated today** to validate microphone positioning
and prepare an explicit input/output contract. **No delays, attenuation,
spill or pickup patterns are yet applied to live instrument audio.**

## Next milestone: safe microphone audio matrix

1. Inspect existing dry-track/audio graph taps to find an appropriate
   pre-effects or pre-fader source signal, preserving musician volume,
   mute, solo, record and latency compensation.
2. Design one preallocated, bounded `source × microphone` matrix with
   stable per-source delays and gain interpolation off the UI thread.
   A microphone receives all eligible audio sources, not only its
   designated instrument section.
3. Build mic output buses and a dedicated Microphone Mixer, with
   level/pan/mute/solo and optional spill isolate controls.
4. Integrate early reflections and a *shared* late-field room send rather
   than creating 32 independent reverbs. Keep the original dry/Apple
   routes until an explicit user selection switches to mic-audition mode.
5. Add phase alignment, audible spill measurements, offline tests,
   and portable-Mac CPU/memory ceilings before enabling mic routing
   as the default path.

All current microphone icons and spill estimates are **editor previews**.
They do **not** play audio or change the current mix in Phase 1.

## Safety and scale

- Object count is capped at 32 capsules to prevent unbounded allocation.
- Geometry calculations allocate nothing in a render callback because
  no runtime microphone audio nodes have yet been inserted.
- Existing Apple Medium Hall, native Room Designer, old
  `StudioVirtualMicrophoneSettings`, instrument positions, early reflections
  and factory profiles remain untouched.
- All edits occur on `feature/stage-acoustics-sync`. There is no merge.
- Live audio, latency, mic-array phasing and full spill behavior need
  the separate next milestone and a consolidated MacBook validation.
