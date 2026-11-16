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
3. SF2: pending RIFF SoundFont parser, PCM sample extraction, preset/instrument
   generator mapping and stereo/loop handling.
4. GIG: pending RIFF/DLS-derived container reader and dimension mapping, with
   attention to format variations and sample encoding.
5. EXS: pending investigation and implementation for accessible legacy EXS24
   instrument definitions and referenced samples.
6. Round-trip validation and consolidated Mac testing.

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
