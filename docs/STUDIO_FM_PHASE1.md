# Studio FM — Phase 1: four-operator synthesis foundation

**Branch:** feature/studio-fm, based on feature/studio-analog.
This work does not modify the sampler branch or the existing analog branch.

## Why FM next?

Our analog synth already covers classic subtractive sounds. A native
four-operator FM engine adds inharmonic bells, electric piano, glassy
mallets, metallic percussion, digital leads and evolving timbres without
importing sample libraries or relying on commercial synthesizer software.

## Implemented in Phase 1

- Original C++17 phase-modulation frequency-modulation (FM) DSP
  compiled into the independent StudioFMDSP Swift Package target.
- Four sine operators with per-operator pitch ratio, level and ADSR.
- Four algorithms: serial cascade; dual two-operator stacks; three
  modulators into one carrier; and four parallel operators.
- Audio-rate operator 4 self-feedback, up to sixteen polyphonic voices,
  automatic released-voice reuse, MIDI channels, pitch bend, sustain
  (CC64), CC120/123, overlapping notes and emergency panic.
- Render-relative MIDI offsets through 65,535 samples. A bounded MIDI
  ring is drained and stably sorted before each audio buffer.
- Thread-safe scalar controls. The audio callback never allocates,
  locks, performs disk access, dispatches tasks, or logs.
- Silent operators avoid unnecessary sine calculation, reducing CPU.
- Soft-limited Float32 planar stereo output for Studio's native mixer.

The implementation is **not an emulation of any proprietary synth**.
All synthesis equations and operator graph algorithms are original.

## Next FM milestones

1. Integrate StudioFMDSP with a Swift AVAudioSourceNode and Studio's
   existing instrument track mixer, stage acoustics and sample-clock MIDI.
2. Add versioned per-track StudioFMPatch persistence and a reusable
   native instrument selection mechanism, leaving ARIA and Analog intact.
3. Build a dedicated FM instrument panel with four operator envelopes,
   ratios, gain, feedback and animated algorithm routing.
4. Add a factory patch bank, safe parameter interpolation, additional
   FM routings, richer velocity/mod-wheel modulation and spectral
   visualizations.

**Not yet integrated in this phase:** Studio instrument picker, DAW track
playback, dedicated FM UI, saving FM presets, or hardware listening.

## Tests

- Standalone sanitizer suite: A440 carrier tuning, FM algorithm
  differences, invalid parameters, channel MIDI offsets, sustain and
  release, emergency panic and bounded stereo output.
- Swift XCTest target with the same key DSP invariants.
- GitHub macOS workflow builds the full Swift package, runs existing
  regressions, and builds optimized DAWApp.

Do not merge this branch without explicit approval. We will use a
single Mac audition milestone once FM is integrated into Studio.
