# Studio Sampler — Milestone 4: External Instrument Compatibility

Status: **In progress**, separate from the frozen Alpha 1 sampler candidate.

## Objective
Import existing sample-based instruments into editable Studio mappings and portable
`.studioinstrument` packages without requiring a commercial sampler or plugin.

## Implementation sequence
1. SFZ mapping reader: implemented initial Foundation-only preview and explicit managed
   sample import. Supports `<control>` default_path, `<global>`, `<group>`,
   `<region>`, sample paths, MIDI keys, velocity limits and explicit loop points.
   Unknown opcodes are reported, not silently treated as working DSP behavior.
2. SFZ user workflow: pending instrument-picker integration, preview of warnings,
   handling of complex opcode expressions, and expanded tests.
3. SF2: **implemented first playable subset**. Native bounded RIFF/pdta
   inspection resolves preset/instrument bags and generators. A chosen preset
   converts to Studio's key/velocity zones; 16-bit PCM mono samples and
   reciprocal linked stereo pairs are extracted as interleaved WAV files.
   Supported sample trim offsets, coarse tuning, sample loops and bank/program
   labels are retained where compatible. The sampler's Instruments menu now
   includes **Import SoundFont 2 (.sf2)…**, preset selection, and warnings.
   Synthetic RIFF regression fixtures exercise preset mapping, mono/stereo
   extraction, missing references and no source-file modifications.
   Outstanding: broader real-library compatibility, modulator/effect/envelope
   translation, larger-than-512-MB banks, and consolidated Mac audition testing.
4. GIG: pending RIFF/DLS-derived container reader and dimension mapping, with
   attention to format variations and sample encoding.
5. EXS: pending investigation and implementation for accessible legacy EXS24
   instrument definitions and referenced samples.
6. Round-trip validation and consolidated Mac testing.

## SoundFont 2 subset and limitations
- One preset is converted at a time, into a draft that must be applied.
- Supported: `smpl` 16-bit PCM, valid mono/linked stereo, instrument and
  preset key/velocity intersections, sample root pitch, coarse tuning,
  supported sample trim offsets and looping.
- Not yet faithful: cents/fine tuning, per-zone gain/pan/filter/envelopes,
  modulation routes, SoundFont effects, ROM/linked-but-not-stereo samples,
  SF3-compressed sources. Import reports generator limitations.
- Source `.sf2` remains untouched. Samples are streamed from the input
  during offline conversion; new WAVs are staged and rolled back on error.
- Current safety cap: **512 MB source files and 128 zones per preset**;
  support for very large orchestral banks is planned after this milestone.

## Compatibility limits
Studio's current native sampler supports at most 128 zones, 4 microphone groups,
15 additional articulations, and a subset of looping and envelope behavior.
An imported mapping must report unsupported opcodes, not claim full fidelity.
External sample formats may require offline conversion into supported audio.
Protected or encrypted commercial libraries are not bypassed.

## Safety
Never alter the original source instrument or recordings. Reject path traversal,
verify source files before copying, and keep imports off the audio thread.
Do not merge into the Alpha 1 integration branch until the product owner authorizes it.
