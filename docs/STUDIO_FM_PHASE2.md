# Studio FM — Phase 2: playable native track integration

Development branch: feature/studio-fm, based on Studio Analog's green branch.

## From the instrument browser

In a MIDI or instrument track, select **Studio FM** in Studio's instrument
browser. Studio creates an original in-process SFMSynth and connects a native
stereo AVAudioSourceNode to the track's existing input mixer. Studio FM
therefore inherits the same fader, pan, metering, and Concert Hall send / stage
position processing as Studio Analog and third-party AU instruments.

The track header's instrument context menu has **Open Studio FM Controls**,
and the track Inspector offers the same control panel. Selecting the native
track in Studio's Instruments lower workspace shows the FM panel in that
workspace without requiring a floating plugin window.

The native synth is independent of third-party installed Audio Units and
independent of the separate native sampler development branch.

## Original four-operator FM panel

- Four per-voice sine operators, each with Ratio (0.125 to 16), Level (0–1),
  Attack, Decay, Sustain and Release controls.
- Select between Serial, Split, Stack and Parallel algorithms with a textual
  signal-flow diagram and descriptions. Controls change the actual C++ DSP
  algorithm, not simply the appearance of an instrument UI.
- Global Feedback, Output gain and MIDI bend range.
- "Audition C4" uses the DAW's existing test-note path.
- "Initialize" restores all 28 FM parameters to the original engine defaults.
- Live edits persist in each track's optional, versioned StudioFMPatch.
- Opening a saved project reconnects the native FM source and restores
  parameter values, without changing Studio Analog's saved sound or ARIA's
  instrument slots. Legacy projects have no FM fields and decode unchanged.

## MIDI, memory and routing safety

- Native note on/off, MIDI channels, sustain CC64 and pitch bend are routed
  by the same TrackInstrument dispatch interfaces already used by the DAW.
- Global Stop triggers FM's high-priority all-notes-off panic to prevent
  sustained notes persisting after playback stops.
- FM parameters are atomic, and its audio callback only reads parameters,
  computes DSP, and writes planar stereo output. It never locks, allocates,
  accesses files or creates UI updates.
- Construction and audio graph attachment happen off the render callback,
  under the same engine-stop / restart transaction as Studio Analog.
- The native FM synth currently accepts bounded relative-sample MIDI offsets.
  Precomputed absolute timeline scheduling inside FM, as used by Studio
  Analog, is a separate follow-up; asynchronous legacy host MIDI delivery may
  introduce jitter on sequenced FM clips. This limitation does not affect
  availability of live MIDI playback or offline audio rendering.

## Automated checks and acceptance

- Original FM C++ DSP with ASan/UBSan.
- Dedicated Swift FM unit tests for A440, modulation algorithms, MIDI timing,
  sustain and invalid parameters.
- FM track integration XCTest: AVAudioSourceNode, offline AVAudioEngine audible
  rendering, track MIDI dispatch, parameter ID parity and patch persistence.
- Full DAWCore regression suite, Debug and optimized DAWApp builds.

Hardware audition remains a separate one-time Mac milestone: load an FM
track, audition, run a MIDI clip, try all algorithms, save/reopen project,
send sustain and bend, move the stage position and confirm Concert Hall,
then verify previously working ARIA and Studio Analog instruments.

Do not merge this branch without explicit product-owner authorization.
