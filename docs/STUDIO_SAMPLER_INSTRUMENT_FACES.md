# Studio Sampler — native instrument front panels and expressive CC engine

Development branch: `feature/studio-sampler-native`.

## Instrument design

`StudioSamplerInstrumentView` is the shared in-app front panel for the same
original Studio Sampler audio engine and per-track sample map. The selected
instrument presentation is optional metadata on `StudioSamplerPatch`,
preserving the ability to open version-1 patches created before this work.

Available presentations:
- **General** — inspect mapped samples and audition the playback engine.
- **Solo Violin** — performance-oriented view for expressive sample layers.
- **Cinematic Percussion** — root-key-linked, playable pads backed by imported
  sample recordings, not synthesised demonstration hits.
- **Choir & Textures** — filename-backed sample layers and live XY dynamics /
  expression control.

The **Edit Mapping** button opens the actual keyboard / velocity editor. This
same instrument panel is available in the Instruments lower workspace, a
track's instrument context menu, and the Inspector.

Presentation selection changes only UI metadata; switching instruments in
the picker does **not** replace samples, change patches, or invent sound
libraries. Users provide their own licensed samples.

## Implemented sound controls

- **CC1 dynamics:** smoothed control over discrete-layer output gain.
- **CC1 crossfade mode:** optional real-time equal-power mixing of up to
  eight dynamic sample zones sharing the nearest recorded root key and a
  matching key range. All layers begin together on note-on; CC1 moves
  between layers continuously on held notes (no retrigger).
- **CC11 expression:** smoothed per-channel amplitude scaling on held notes.
- **Audition:** performance preview buttons, percussion pad triggers, and
  the basic on-screen keyboard send MIDI into the real track instrument,
  then send a note-off.
- **Project persistence:** front-panel kind, CC1/CC11 initial values and
  crossfade mode are saved as optional fields in existing sampler patches.
- All mode/controller changes enter the existing serialized C++ command
  queue; they never rewire the audio graph or replace samples while playing.

The DSP precomputes neighboring layer centers at note-on for O(1)
render-time per-voice layer weights. Controller values are smoothed over
approximately 10 ms and should never be read or mutated directly across
threads.

## Explicit limitations

- This is an increment, not a fully sampled orchestral library.
- No built-in violin, percussion, or choir recordings are distributed.
- There is no sustained sample looping, ADSR, legato transitions,
  articulation keyswitching, mic-multitrack mixing, sophisticated
  vibrato, convolution reverb, or granular XY texture morphing yet.
- Equal-power interpolation between unrelated recordings can reveal
  phase interaction; precise sample alignment and intelligent loudness
  matching are later milestones.
- A maximum of eight overlapping dynamic zones per root can be activated
  in CC1 mode for bounded polyphony. A default of 32 native voices is
  shared across active notes.
- No disk streaming yet. Large RAM-backed sample sets remain limited
  by the earlier source frame count bounds.
- CC1 crossfade changes apply to notes triggered AFTER the toggle.
- The alternative Core Audio backend is not yet supported.

## Build and regression verification

The repo's dedicated `studio-sampler.yml` workflow compiles:
- The native DSP with AddressSanitizer and Undefined Behavior Sanitizer,
  including CC1 sustained-note crossfade and CC11 fade tests.
- The whole Swift package on macOS.
- The existing DAWCore and sampler-related Swift tests.
- The optimized DAWApp product.

Do not report that hardware playback or the full UI is verified until
the macOS CI and a later Mac listening milestone pass.
