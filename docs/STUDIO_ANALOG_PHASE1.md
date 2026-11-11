# Studio Analog — original modular virtual-analog synth

Status: **Phase 3 native control panel**. Studio Analog has a SwiftUI analog
control surface in the Instruments lower workspace and track/Inspector sheets.
It displays and edits every sound parameter currently supported by the engine,
with project-persisted per-track patches and initialized values.

Studio Analog can now be selected
in the existing track instrument browser. It uses an in-process
`AVAudioSourceNode` to route its original DSP through Studio's existing track
mixer, panner, meters, and Concert Hall sends. No third-party AU is required.
The visual modular patchboard remains future work.

## Design and provenance

- DSP is authored for Garritan Studio in C++17; there is **no third-party synth
  engine, synthesis library, sample content, or bundled vendor code**.
- Apple/Swift Package toolchains supply standard C++ facilities and build support.
- `StudioAnalogDSP.h` exposes a stable C ABI that Swift can use without enabling
  C++ interoperability for the existing DAW targets.
- Graph nodes: two oscillators, noise, mixer, filter envelope, LFO, resonant
  low-pass filter, amplitude envelope, VCA, output.
- **Real graph execution:** patch routes are compiled into a topological order,
  checked for matching audio/control ports, cycles and duplicate inputs. Audio
  rendering evaluates the compiled graph, not a separate hard-coded signal chain.
- Saw and pulse oscillator discontinuities use polyBLEP correction; the triangle
  is initially a basic digital triangle, to be refined before release.
- Resonant filter uses a topology-preserving state-variable low-pass.
- 1–16 voices (8 recommended), linear ADSR, oscillator tuning, velocity,
  filter-envelope modulation, LFO modulation, and bounded output.
- Native stereo planar float rendering. No external plug-ins required.

## Threading rules

`sa_render` is exclusively called from **one** audio render thread. It performs
no heap allocation, lock acquisition, logging, or graph recompilation.
`sa_note_on`, `sa_note_off` and `sa_all_notes_off` use a bounded, lock-free
single-producer/single-consumer MIDI ring. Call them from one producer thread.
Parameter values are exchanged atomically and snapshotted at render-block start.

**Important:** `sa_load_patch` is intentionally **not live-edit safe**. It is
used while audio is stopped. Before enabling interactive patch cables, add
versioned immutable graph snapshots and a safe render-boundary swap with
lifetime management. Do not mutate the graph from a SwiftUI callback.

Note events currently apply at the beginning of the next render block, not
at sample offsets. Sample-accurate event offsets, sustain pedal, pitch bend,
voice crossfades on stealing, note overlap ownership and serializable patches
are next-stage work.

## Tests

```sh
swift test --filter StudioAnalogDSPTests
swift build --target StudioAnalogDSP
```

Tests cover 440 Hz pitch, release to silence, polyphonic rendering, parameter
validation, safe rejection of a cyclic graph and bounded queue behavior.
Hardware/AVAudioEngine playback is **not** claimed by these tests.

## Phase 2 integration

- The native synth is shown as a built-in instrument in the regular browser.
  Choosing it loads a dedicated AVAudioSourceNode into the current track's
  existing mixer path. Selecting a third-party AU later replaces it normally.
- Track selection is saved with `studioAnalogEnabled` (optional for
  backward-compatible decoding) and recreated when a project is opened.
- The render callback owns a retained C++ synth instance and uses planar
  Float32 output; source-node removal stops the AVAudioEngine before detach.
- Because live and sequenced MIDI can arrive from two producer threads, the
  Swift bridge serializes producer pushes with a lock outside the audio thread.
  The render callback remains lock-free.
- Current limitations: native synth track audio requires the legacy
  AVAudioEngine backend; sample-offset MIDI, pitch bend, sustain and live
  cable-routing are not implemented yet.
- Manual listening and stage-routing verification remain needed on macOS.

## Phase 3 controls and presets

- Analog control panel: oscillators (sine/triangle/saw/pulse), mixing, shared
  pulse width, oscillator-2 tuning, resonant filter and envelope depth, ADSR
  for filter and amplitude, sine LFO rate/depth and master gain.
- Controls update C++ atomic parameters while sounding; no graph mutations or
  locks occur in the audio callback. Logarithmic UI travel for frequency and
  ADSR times makes practical adjustment easier.
- A versioned optional `studioAnalogPatch` persists only per-track parameter
  overrides and falls back to engine defaults if absent/invalid. A parameter
  compatibility test checks every Swift default against C++ runtime values.
- `Initialize` restores the default sound and saved patch state. `Audition C4`
  triggers Studio's existing 500 ms MIDI test-note path. The 8-module control
  surface does not yet provide a freely cabled routing editor.
- Native sound controls appear in the Instruments lower workspace for the
  selected Studio Analog track and in a sheet opened from the track slot or
  inspector. Other instrument tracks still use the existing V-Rack workspace.
- Slider changes directly update project state rather than generating many
  undo entries per gesture. A consolidated undoable gesture is future work.

## Next step

Implement a visual modular patchboard with typed patch cables, immutable
compiled graph snapshots and safe render-boundary graph swaps. Add sample-
offset MIDI, pitch bend and CC routing before production release.
