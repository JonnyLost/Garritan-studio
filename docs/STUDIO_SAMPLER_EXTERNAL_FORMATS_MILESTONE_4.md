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
4. GIG: **implemented first conservative import subset.** Native bounded
   RIFF/DLS reader inspects `lins` instruments, `lrgn` key/velocity regions,
   `ptbl` sample cues, `wvpl` waves, `wsmp` loops and GIG-specific
   `3lnk` dimension links and `3prg/3ewl` articulations. Supports
   selecting one instrument and copying validated **single-dimension,
   uncompressed 16-bit PCM** mono/stereo recordings as WAV files into
   Studio's managed sample library. The mapping is staged for Apply.
   More complex GIG dimensions or compressed/unknown samples are
   intentionally rejected rather than silently losing layers.
   Synthetic regression tests cover a playable RIFF/DLS GIG fixture,
   source-file immutability, dimensions, compressed/unsupported audio,
   and damaged containers. Pending: real-world GIG file compatibility,
   GIG 3+ extended containers, 24-bit/compressed wave decoding,
   velocity/articulation dimensions, envelopes/filters/LFO, and Mac audition.
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

## GigaStudio support boundary

**Implemented:** browsing instrument names/programs and native import of
GIG regions with supported velocity/round-robin/release dimensions and
conventional PCM wave data. Interprets GIG
`3lnk` sample-pool references (distinct from DLS `wlnk`), GIG
`3ewl` sample parameters, key/velocity bounds, and sample loops.
WAV extraction is offline, staged, transactional and leaves the source intact.

**Milestone 4.6 — GIG dimension mapping (implemented, CI pending):**
- `3lnk` entries now decode a case count, a typed list of dimension
  definitions (each with its split-bit width), and case-specific wave-pool
  links. `3prg/3ewl` parameters are assigned per case.
- Supported dimensions: GigaStudio **velocity** (0x82, regular 128-step
  splits), **note-on round robin** (0x86, up to eight alternatives),
  and **release trigger** (0x84, one sustain and one note-off case).
  Multiple supported dimensions can be composed together with bit-packed
  case selection.
- Converted zones preserve original note/velocity intersections, per-case
  sample references and loop parameters (release samples have no sustain
  loops). The import remains transactional, deduplicates extracted WAVs,
  and runs offline.
- Unknown or currently unrepresentable dimensions are explicitly rejected:
  keyswitch selection, random, simultaneous layers, controller switches,
  crossfades, sample channel, and Smart MIDI.
- GIG3 *custom* velocity boundaries, per-case fine tuning, and round-robin
  global counter semantics require further work. The importer warns when
  regular split assumptions apply. Native application and audio testing
  remain pending.
- Synthetic tests cover single and combined dimensions, RR alternate
  selection, release triggers, malformed bit counts, layer/keyswitch
  rejection, and preserved source GIG bytes.

**Still not implemented:** multi-dimension GIG instruments beyond the
listed supported dimension kinds (or cases beyond native sampler limits) (including layered
velocity/crossfade, round-robin, keyswitches, release samples, pedal and
controller dimensions), compressed GIG wave decoding, GIG v3/v4 extended
RIFF containers, finer per-dimension tuning, filters and modulation.
A failure in this subset is **not evidence that a library is corrupted**.
The importer must refuse unsupported regions instead of pretending that
only the DLS base sample link fully represents a GigaStudio instrument.

**Licensing:** GIG structure research was informed by publicly documented
RIFF/DLS layout and format observations, but the implementation is original
Swift/Foundation code, with no libgig dependency. libgig is GPL-licensed;
integrating it would require separate licensing and architecture review.

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
