# Studio Physical Modeling DSP

Native C++17 synthesis core exposed to Swift through `StudioPhysicalDSP.h`.
The DSP now connects to Studio Synth's individual and Hybrid layers on
`feature/studio-synth`. StudioPhysicalInstrument uses AVAudioSourceNode and
the existing per-layer mixer; StudioPhysicalPatch preserves projects and
StudioPhysicalFactoryLibrary provides twelve original starting patches. The
Studio Synth panel exposes physical model selection and model-specific controls,
and the common modulation and MIDI Learn systems can address continuous
parameters. No commercial plugins, sampled instruments or additional runtime
DSP dependencies are required.

## Integration and verification

- `DAWCore/Sources/DAWCore/Audio/StudioPhysicalInstrument.swift`: native
  renderer, MIDI producer lock and planar audio source node.
- `StudioPhysicalPatch.swift` and `StudioPhysicalPresets.swift`: saved
  parameter identities and twelve factory configurations.
- `StudioSynthInstrument.swift`: Hybrid and single-engine mixer/MIDI routing.
- `StudioSynthModulation.swift`: continuous modulation and MIDI Learn targets.
- `StudioSynthPanelView.swift`: new Physical tab, factory sounds and controls.
- `Tests/DAWCoreTests/StudioPhysicalIntegrationTests.swift`: patch persistence,
  factory distinctness, audio-graph offline rendering and hybrid MIDI behavior.
- `Tests/StudioPhysicalDSPStandalone/main.cpp`: Linux/CI sanitizer exercise
  for all eight models at six sample rates.

The original native output is mono copied to two planar channels; the Studio
layer mixer applies pan and gain. Project files store only data, never pointers.

## Model IDs

| Value | Model | Excitation |
| --- | --- | --- |
| 0 | Plucked string | Initial displaced string |
| 1 | Struck string | Damped impact noise |
| 2 | Bowed string | Continuous stick/slip-like friction |
| 3 | Reed wind | Breath-driven reed valve |
| 4 | Brass | Breath-driven lip valve |
| 5 | Tuned mallet | Six decaying, bar-like modes |
| 6 | Bell | Six decaying, metallic inharmonic modes |
| 7 | Membrane | Six decaying membrane-like modes |

The percussion models use six fixed-capacity complex modal oscillators per
voice, with frequency ratios based on instrument families. Modal frequencies,
decay constants and amplitudes are prepared at note start; pitch bend retunes
active modes without resetting their ringing state. Partial frequencies at or
above 45% of the sample rate are skipped to limit aliasing. No memory allocation,
locks, I/O, or trigonometric calculations occur in per-sample rendering.

### Percussion controls

- `SPM_PARAM_PERC_HARDNESS` (17): high-mode energy and transient duration
- `SPM_PARAM_PERC_DECAY` (18): modal ringing time
- `SPM_PARAM_PERC_INHARMONICITY` (19): interpolate between harmonic and material-specific frequency ratios
- `SPM_PARAM_PERC_ATTACK_NOISE` (20): short strike-noise burst
- Existing `SPM_PARAM_POSITION` (3) shapes the modal excitation spectrum
- Existing `SPM_PARAM_RELEASE` (5) damps ringing after note-off

All new controls use normalized 0–1 values; the original parameter IDs are
unchanged. The model parameter accepts integer-valued floats 0 through 7.

## MIDI and real-time contract

MIDI note-on/off, CC1, CC2, CC11, CC64, CC120/123 and pitch bend are supported.
Events are queued by one serialized producer and consumed on the audio thread,
with frame offsets carried across render buffers. Eight voices maximum. The
synth writes identical left/right samples; the parent Studio Synth mixer
applies each layer's pan and level. Create/destroy/reset are **not** audio-thread operations.

## Verification

`Tests/StudioPhysicalDSPTests` covers basic tuning, MIDI timing, sustain,
panic, expression, and the percussion models' timbral differences, natural
decay, pitch bend and parameter validation. Run on a Mac:

```sh
swift test --filter StudioPhysicalDSPTests
```

The modal oscillator mathematics were also checked in a separate local C++17
harness at 8, 44.1, 48, 96, 192 and 384 kHz with AddressSanitizer and
UndefinedBehaviorSanitizer. **That isolated check is not a substitute for
building this full Swift package or listening to the instruments on macOS.**

## Current limitations

These are first-pass synthetic models, not acoustically calibrated or
performance-validated orchestral instruments. In particular, realistic
mallet/metal plate radiation, membrane coupling, fine-grained key-off damping,
velocity layering, articulations, stereo radiation and detailed instrument
calibration remain future work. First-pass factory sounds are synthesis
starting points, not certified acoustic instrument recreations. Preserve the existing synth branch and do not
merge it without the product owner's authorization.
