# Studio Analog — original modular virtual-analog synth

Status: **Phase 1 DSP foundation**. This branch adds a built-in synthesis engine
without modifying ARIA, Garritan instrument routing, stage acoustics, or the DAW
application UI. The synthesizer is not yet selectable as a Studio track instrument.

## Design and provenance

- DSP is authored for Garritan Studio in C++17; there is **no third-party synth
  engine, synthesis library, sample content, or bundled vendor code**.
- Apple/Swift Package toolchains supply standard C++ facilities and build support.
- \`StudioAnalogDSP.h\` exposes a stable C ABI that Swift can use without enabling
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

\`sa_render\` is exclusively called from **one** audio render thread. It performs
no heap allocation, lock acquisition, logging, or graph recompilation.
\`sa_note_on\`, \`sa_note_off\` and \`sa_all_notes_off\` use a bounded, lock-free
single-producer/single-consumer MIDI ring. Call them from one producer thread.
Parameter values are exchanged atomically and snapshotted at render-block start.

**Important:** \`sa_load_patch\` is intentionally **not live-edit safe**. It is
used while audio is stopped. Before enabling interactive patch cables, add
versioned immutable graph snapshots and a safe render-boundary swap with
lifetime management. Do not mutate the graph from a SwiftUI callback.

Note events currently apply at the beginning of the next render block, not
at sample offsets. Sample-accurate event offsets, sustain pedal, pitch bend,
voice crossfades on stealing, note overlap ownership and serializable patches
are next-stage work.

## Tests

\`\`\`sh
swift test --filter StudioAnalogDSPTests
swift build --target StudioAnalogDSP
\`\`\`

Tests cover 440 Hz pitch, release to silence, polyphonic rendering, parameter
validation, safe rejection of a cyclic graph and bounded queue behavior.
Hardware/AVAudioEngine playback is **not** claimed by these tests.

## Next step

Connect the engine through a dedicated Studio audio-source adapter and route
it to an instrument track with MIDI, mute/solo, stage reverb sends and project
persistence, before designing the full Analog/Modular SwiftUI panels. Keep
the adapter independent from ARIA and the existing plugin hosting path.
