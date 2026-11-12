# Studio Sampler — Sample Fades, Loop Suggestions & Articulations

Feature branch: `feature/studio-sampler-native`.

This milestone extends the original native C++ sample playback engine and
in-app SwiftUI sampler editors. No third-party DSP, new plug-ins, commercial
sample libraries, or subscriptions are introduced.

## Sample-boundary fades

- Every sample zone can optionally specify `fadeInFrames` and
  `fadeOutFrames` measured in the original source sample frames.
- The audio renderer applies lightweight linear amplitude ramps at the
  start/end of the region, in addition to the instrument's separate ADSR.
- Fades and trims are nondestructive: imported audio files are not rewritten.
- The waveform editor presents Fade In and Fade Out sliders in milliseconds,
  using source sample rate for accurate labeling.
- Fade lengths must fit within the trimmed playback region; the Swift
  model, Swift decoder/loader and native DSP enforce the bounds.

## Automatic loop-point suggestion

- **Find Loop** in the waveform editor runs on a detached utility task.
- It inspects two short, bounded PCM windows, roughly near the first and
  last thirds of the selected playback region.
- A native, coarse-to-fine waveform-shape similarity search considers both
  channels. It suggests source-frame start/end positions and a crossfade.
- It intentionally rejects a low-confidence match rather than guaranteeing
  that every recording can sustain transparently.
- The results are **draft suggestions only**. Review the waveform and
  click **Apply Mapping** before the audio engine uses them.
- Large recordings are never decoded in their entirety just to find loops.
- Real-time audio rendering is unaffected by the analysis.

## First articulation implementation

- A sample zone can be assigned to the default recorded articulation (ID 0)
  or one of up to 15 additional named articulation groups.
- New groups are created in Studio Sampler's keyboard/velocity mapping
  panel. Edit names and the MIDI keyswitch note per group, then assign
  each recording to a group via the zone Articulation picker.
- The keyswitch map is validated for duplicate MIDI notes/IDs and copied
  into the native engine before rendering begins.
- Incoming note-on messages for configured keyswitches update the active
  articulation for that MIDI channel and are not sounded as instrument
  notes. Note-offs of keyswitches are ignored.
- Front-panel articulation buttons explicitly select a group for subsequent
  notes, using the native MIDI command queue.
- Already sounding notes remain untouched when switching articulations.
- The instrument model stores articulation groups, each zone's articulation,
  and the chosen startup articulation. Older projects default to ID 0.
- MIDI keyswitches take priority when their pitch overlaps a sampled key
  range. Choose dedicated low keys if you wish to retain the full range of
  musical notes.
- The front-panel selection reflects front-panel actions; external MIDI
  keyswitches currently change the native engine but do not feed their
  selection back to the SwiftUI selection indicator.

## Known follow-on work

- Factory orchestral instruments do not yet exist. Real articulation
  recordings must be imported by the user or created with Studio.
- The initial articulation engine does not provide intelligent legato,
  bow change/transition synthesis, true round-robin sequencing, release
  trigger samples, or articulation-specific envelopes.
- Sample library data remains fully resident in bounded RAM rather than
  disk-streamed. Auto-loop detection is a best-effort analysis.
- Smoothing loop edges, zero-crossing alignment, stereo analysis and
  offline scoring can be refined based on real recordings.
- Native sampler's alternate Core Audio backend requires separate support.

## Tests

- `Tests/StudioSamplerDSPStandalone/main.cpp` verifies faded playback,
  articulation zone routing, MIDI keyswitch priority and channel isolation.
- `Tests/DAWCoreTests/StudioSamplerTrackIntegrationTests.swift` verifies
  decoding/persistence of fade and articulation maps, invalid mapping
  rejection, and non-destructive loop-point suggestions.
- `studio-sampler.yml` performs native DSP ASan/UBSan, macOS Swift builds,
  existing DAWCore regression tests, and optimized DAWApp compilation.

Only report the current feature as fully CI-verified after those jobs pass,
and reserve an actual Mac listening test for the consolidated milestone.
