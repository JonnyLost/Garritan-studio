# Studio Native Microphone Capture & Mic Mixer — Audible Milestone 2

**Branch:** `feature/stage-acoustics-sync`  
**Status:** Experimental first audible source-to-microphone and spill-routing implementation.
**Default:** Original direct + Concert Hall routing is unchanged until the composer explicitly selects **Rooms → Mic Mixer → Audition Microphones**.

## What the first audible system does

Studio now has an original native `NativeMicrophoneSpillAudioUnit`,
wrapping `NativeMicrophoneSpillProcessor`. One capture instance
receives **one participating track's post-insert, pre-pan stereo signal**
and produces a single microphone-capsule result.

A microphone receives independently delayed contributions from
**every included source**—not just the section closest to it.
The current capture estimates use the actual persisted microphone
position, height, aim and polar response together with Studio's
existing stage-pan/zone mapping:

- **Distance gain and signed pickup:** appropriate directional
  attenuation and rear-lobe polarity. One-meter reference limits
  gain close to capsules.
- **Travel time:** delayed by distance / 343 m/s, 0–450 ms supported.
- **Air loss:** a bounded, low-cost one-pole lowpass approximation.
- **Live movement:** smooth gain, delay and filter changes at the
  Audio Unit render rate. The *initial* delay is set exactly before
  rendering, avoiding an early sound burst.
- **Track controls:** source gain follows post-track volume,
  mute and solo; input comes before the old stage stereo panner.
- **Microphone mix:** up to **four audible mic channels** feed one
  microphone audition return, each with saved gain, pan, mute and
  solo. XY/ORTF/Decca array templates start with useful stereo panning.

The first graph deliberately uses **one original Audio Unit per
(source,mic) pair**, limited to **16 participating track sources × 4
microphones (64 capture nodes)**. This bounded prototype is
straightforward to isolate and test, but does not yet have the
efficiency of the planned consolidated multi-source mixer kernel.
The persisted microphone editor still supports 32 objects; only the
first four take part in live audition.

## Signal paths and monitoring isolation

Original path (always constructed):

```
Track input → insert effects → gain → stage stereo panner
  ├→ original direct track mixer → master
  ├→ per-track hall send → shared room/Apple reverb
  └→ original native early reflections → hall return (when selected)
```

The first audition path (constructed only when enabled, engine stopped):

```
Track input → insert effects → gain [PRE-PAN]
  ├→ original stage panner (still connected, monitoring muted)
  ├→ source/mic capture AU → Mic 1 bus (level/pan/mute/solo)
  ├→ source/mic capture AU → Mic 2 bus (level/pan/mute/solo)
  ├→ source/mic capture AU → Mic 3 bus (level/pan/mute/solo)
  └→ source/mic capture AU → Mic 4 bus (level/pan/mute/solo)
                               ↓
                        Mic Audition Return → Master
```

While microphone audition is enabled, Studio mutes the original
per-track direct outputs and the hall return, **not merely adding
mic outputs in parallel**. The mic return is silent until explicitly
activated. Switching back removes capture nodes, restores the
original gain-to-panner connections, dry track output and hall return.
Failed engine startup during mic graph setup attempts to roll back
to the original routing.

**Milestone 3 shared-field integration:** Microphone audition now blends
an adjustable fraction (0–100%, initially 20%) of the **existing single
shared hall return** into the mic audition. Studio's normal dry orchestra
is still muted while auditioning; the wet trim is independent of the
normal hall return level and is not stored as a mic capsule setting.
At 0% the microphone audition remains direct/spill-only. The shared
return is driven by existing stage-positioned track sends (and existing
native early reflections when selected), **not** individual microphones'
physical positions. Therefore this is an intentionally approximate room
field, not microphone-specific early-reflection modeling, measured mic
impulses, or a guarantee of physical phase coherence. Per-mic reflection
routing and alignment remain to be implemented. Some separate routing paths, such as
V-Rack output and metronome, are not necessarily included in the
per-track capture matrix and require dedicated evaluation.

## UI workflow

1. Place instruments in **Stage** and add microphones using **Stage
   → Add Spot Mic** or **Rooms → Microphones** (Spot, XY, ORTF, Decca).
2. Position/aim them and set pickup patterns, then open **Rooms → Mic Mixer**.
3. **With transport stopped**, press **Audition Microphones**. Adjust **Shared room return** to blend one wet hall field, or set it to 0% to isolate simulated direct/spill. Stop
   audition to add or remove mic objects.
4. Move/aim mics and adjust microphone channel levels/pan/mute/solo
   while hearing the synthetic capture. Multiple instrument sources
   feed each active mic according to their distance and orientation.
5. Press **Return to Original Mix** (while stopped) to restore the
   prior dry/hall sound. No mic audition state is automatically
   restored when a project is reopened.

Mic mixer settings are optional fields on the persisted microphone
objects, allowing projects created in Phase 1 to load unchanged.
Project positions, presets and previous global virtual listening
settings also remain intact.

## Real-time constraints

- DSP allocates a fixed delay ring during AU allocation, never on
  the audio callback. AU parameter writes communicate bounded gain,
  delay and lowpass coefficient values, while continuous values
  are smoothed in the DSP.
- All graph topology edits take place with the engine stopped,
  matching the existing Studio track-creation/reverb strategy.
- Add/remove mic objects while audition is active is refused;
  stage instrument moves and mic controls are parameter updates.
- The prototype source cap prevents an unbounded per-pair AU graph;
  adding a new track that would exceed the cap restores the
  original mix rather than silently dropping the new source.
- The microphone mixer currently has **no mic-specific insert
  effects**, destructive microphone export, time-alignment display,
  or isolated mic stems. Those remain future milestones.

## Validation and next work

Automated processor tests exercise actual delayed audio output,
block-size independence, signed rear lobes, mute, lowpass, smoothing,
nonfinite input, and backward-compatible channel setting persistence.
The macOS workflow compiles the application, runs those regressions
and checks the existing acoustic-room calibration pipeline.

**Important:** An automated build cannot prove audible device routing,
quality of the spatial illusion, or full MacBook orchestral CPU/memory
performance. Those need a consolidated listening/latency/performance
milestone. Do not claim that a named room's recorded microphone signal
can be reproduced from dry source samples.

Next work should prioritize a more efficient single matrix engine
for large orchestras; microphone-dependent early-reflection geometry
and phase/latency alignment; source-directivity and frequency-dependent
air loss; V-Rack routing parity; mic-bus meters; optional mic/stem
exports; and one consolidated MacBook test. Milestone 3 shared-field
routing is committed but **not yet Mac-build or listening verified**.

## Follow-on: manual microphone timing alignment (November 14, 2026)

Mic Mixer channels now have a persistent, optional **Align** control with
0.1 ms editing steps from -20 to +20 ms and a **Zero** reset. The trim is
added to the modeled source-to-capsule propagation delay for *every* source
received by that capsule, bounded by the existing 0–450 ms AU range.
A negative trim can shorten travel delay only down to zero: it cannot
predict future signal or implement true negative-time latency compensation.
Zero is the backward-compatible default for existing projects, and
non-finite/out-of-range stored values are safely normalized.

The existing AU delay renderer interpolates fractional sample positions
and retains signed rear-lobe polarity; regression tests cover its
fractional-delay behavior and saved/legacy alignment values.
This is **manual temporal calibration**, not automatic cross-correlation,
full-band phase matching, mic-array time-of-arrival calibration, or
latency compensation for the shared hall return. Comb filtering may still
occur between microphone channels, particularly when capturing the same
source with differing delays. Microphone gain/polarity also depend on
source geometry and the chosen pattern, and no real microphone IR is used.

**Performance and routing still open:** the live prototype remains
16 sources × 4 microphone channels (up to 64 source/mic capture AUs).
No increase to this limit is warranted before a single preallocated
matrix renderer is implemented, benchmarked, and tested. V-Rack inputs
remain outside this proof-of-concept path. New code is not counted as
macOS-build verified until the matching GitHub workflow succeeds; device
listening and orchestral load tests are still a consolidated Mac milestone.

## Shared-history matrix DSP foundation (November 14, 2026)

The native `NativeMicrophoneCaptureMatrix` and its dedicated XCTest
regressions are now available on this feature branch. The processor prepares
a single ring buffer per participating source, then independently evaluates
each microphone's signed gain, fractional time of flight, low-pass damping,
and smoothed automation. It supports bounded configurations of 1–64
sources and 1–4 microphones and rejects out-of-range cardinalities.

At the same sample rate and source count, the **history storage** scales as
`sourceCount × delayCapacity` rather than
`sourceCount × microphoneCount × delayCapacity`. For 64 sources and four
microphones, this is a theoretical fourfold reduction in historical samples
compared with separate source/mic processors. This is NOT a benchmark or a
claim of fourfold overall RAM or CPU improvement. Per-pair filter state and
source-to-mic calculations still scale with the number of pairs.

**Integration gate:** This is an offline-ready DSP foundation, not yet a
replacement for the live mic audition Audio Units. The current live system
still allows only 16 sources × 4 microphone channels, and it retains its
existing rollback to the original dry/hall mix. A future integration must
transport distinct pre-pan track streams to a single render callback with
explicit bus ordering, cross-block synchronization, and sample-accurate
timing. It must not use asynchronous AVAudioNode taps as if they were
real-time-safe, synchronous audio inputs. It must also preserve
mic mute/solo/pan, live stage movement, the shared hall return,
per-track insert routing, track creation/removal and V-Rack isolation.

**Validation gate:** Run the macOS app build and the added matrix
regressions on this exact commit, then compare offline output against the
existing per-pair renderer and benchmark realistic 16/32/64-source sessions
before switching any live signal path. Device listening and larger
orchestral performance remain unverified until the consolidated Mac test.

## Experimental live shared-history backend (November 14, 2026)

The **Mic Mixer** now offers an explicit, nonpersistent toggle:
**Experimental shared-history capture (one Audio Unit per source)**.
This is available only while microphone audition is inactive; the
verified legacy per-(source,mic) capture remains the default. The new
native `NativeMicrophoneMatrixAudioUnit` connects one pre-pan source
to four dedicated stereo output busses, each routed to the existing
mic mixer. All four capsule results are computed once per shared
`AudioTimeStamp.mSampleTime`, with their output samples cached so a
second output bus does not pull the source or advance its delay line again.
Existing signed pickup, mic alignment, solo/mute/pan, smooth movement,
per-track volume, stage sends, shared hall wet trim, and rollback to
the original mix are retained. The Audio Unit uses the existing
`NativeMicrophoneCaptureMatrix` with one source and four microphones,
including a newly exposed pointer-buffer rendering API to avoid
constructing Swift arrays in the audio callback.

**Important architectural distinction:** this is **one Audio Unit per
source**, not yet one Audio Unit for an entire 64-source orchestra.
For a 16-source, 4-mic audition it changes the capture topology from
64 processing Audio Units to 16, while sharing one source history across
all four capsules in each unit. The 64-source capability of the standalone
matrix DSP is NOT yet the live engine limit. Live audition still caps
at 16 sources and 4 microphones, irrespective of the selected backend.
V-Rack signal injection and single-AU multi-source synchronization
remain separate engineering work.

The experimental engine may fail on unsupported multi-output host graphs;
its failure path removes the audition graph and restores Studio's original
dry/hall routing. The toggle cannot change a running audition graph.
Its only safe promotion path is a successful macOS build and deterministic
multi-bus AVAudioEngine smoke test, then actual multi-source MacBook
listening and CPU/underrun stress measurements. Do not declare latency,
sound quality, multi-bus host compatibility, or 64-source scalability
validated from DSP unit tests alone. No previously working route is
made dependent on this experimental backend.
