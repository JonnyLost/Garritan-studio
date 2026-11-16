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
   selecting one instrument and copying validated **uncompressed 16-bit
   PCM** mono/stereo recordings as WAV files into Studio's managed sample
   library. Supported GIG dimensions include regular velocity bands,
   round-robin, release triggers, explicit keyboard keyswitches and stepped
   CC1/CC2 sample selection. The mapping is staged for Apply.
   Other complex GIG dimensions and compressed/unknown samples are rejected
   rather than silently losing layers.
   Synthetic regression tests cover a playable RIFF/DLS GIG fixture,
   source-file immutability, dimensions, compressed/unsupported audio,
   and damaged containers. Pending: real-world GIG file compatibility,
   GIG 3+ extended containers, 24-bit/compressed wave decoding,
   expanded dimension types, envelopes/filters/LFO, and Mac audition.
5. EXS24: **first native import subset implemented (Milestone 4.8)**.
   A bounded, dependency-free Swift reader handles legacy little-endian
   TBOS/JBOS .exs blocks, instrument names, sample references, zone key/velocity
   bounds, trims, forward loops and basic groups. The importer resolves WAV,
   AIFF or CAF audio from the instrument folder/Samples folder or an existing
   stored path, validates the audio, deduplicates and copies recordings into
   Studio's managed library, and stages a native editable mapping.
   Studio's Instruments menu now offers **Import Logic EXS24 (.exs)…**.
   Unsupported behaviors are explicitly rejected rather than silently
   changing playback. Synthetic EXS + WAV fixtures exercise decoding,
   velocity ranges, loops, groups, missing audio, malformed blocks and
   non-destructive imports. **Milestone 4.9** adds bounded EXS
   Select Group By translation: round-robin positions 0...7,
   note-selected keyswitch articulation groups with preserved MIDI notes,
   and CC1/CC2 group selection only where ranges divide the MIDI controller
   space into regular, contiguous bands. The reader also now uses the
   actual 32-bit EXS block length. Real EXS library testing and Mac build
   verification remain pending.
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
  random, simultaneous layers, most controller switches, crossfades, sample
  channel, and Smart MIDI.
- GIG3 *custom* velocity boundaries, per-case fine tuning, and round-robin
  global counter semantics require further work. The importer warns when
  regular split assumptions apply. Native application and audio testing
  remain pending.
- Synthetic tests cover single and combined dimensions, RR alternate
  selection, release triggers, malformed bit counts, layer/keyswitch
  rejection, and preserved source GIG bytes.

**Milestone 4.7 — GIG keyswitch and controller selection (implementation
committed; validation pending):**
- Read explicit instrument `lart/3ewg` keyswitch boundaries. A GIG
  keyboard dimension (0x85) maps each case to a native articulation
  with actual switch notes; case zero is the default switch. Missing,
  contradictory, or overlapping switch-key metadata aborts import.
- GIG modulation wheel (0x01 / CC1) and breath (0x02 / CC2) cases
  map to a version-1 compatible optional controller-switch descriptor
  in `StudioSamplerPatch`. The native C++ sampler selects the correct
  articulation from equally spaced controller bands on **note-on**;
  held voices retain their original articulation. The setting is
  configured once before rendering, is optional for old projects, and
  performs no heap allocation or locks on the render thread.
- Only one selection dimension (keyswitch OR CC1 OR CC2) is permitted
  per instrument, consistently across all regions. It can be combined
  with supported velocity, round-robin, and release dimensions.
- For controller-switched instruments, CC1/CC2 choose discrete
  articulation bands. CC2 breath-volume attenuation is disabled for
  CC2-switched patches to avoid silencing the lowest controller band.
  Normal sampler instruments retain their previous CC2 expression.
  Advanced GIG continuous crossfades are NOT reproduced.
- In the absence of explicit saved CC1/CC2 state, Studio restores the
  controller band matching the saved selected articulation instead of
  unexpectedly selecting the highest band on initialization.
- Includes deterministic synthetic fixtures for keyboard/CC1/CC2
  combinations and native standalone CC switching tests.

**Still not implemented:** unrecognized or mixed selector dimensions,
simultaneous layer/crossfade, pedal switches, aftertouch and Smart MIDI,
custom split thresholds, GIG compression and v3/v4 extended RIFF
containers, per-dimension fine tuning and filters/modulation.
A failure in this subset is **not evidence that a library is corrupted**.
The importer must refuse unsupported regions instead of pretending that
only the DLS base sample link fully represents a GigaStudio instrument.

**Licensing:** GIG structure research was informed by publicly documented
RIFF/DLS layout and format observations, but the implementation is original
Swift/Foundation code, with no libgig dependency. libgig is GPL-licensed;
integrating it would require separate licensing and architecture review.

## EXS24 support boundary

**Supported now:**
- Legacy, little-endian TBOS/JBOS block files, up to 16 MB instrument metadata.
- A single instrument per .exs, 1–128 sample zones; absolute or sibling
  sample references only when they resolve to actual WAV, AIFF or CAF audio.
- Key/velocity zones, root note and semitone tuning, per-zone trim frames,
  basic groups with optional velocity intersection, forward sustain loop and
  bounded loop crossfade. EXS volume/pan/fine tuning differences are warned.
- Basic release-trigger groups (without active sample looping).
- Source files remain unchanged. Duplicate references share one managed copy.
  No Logic or commercial sampler runtime is required.

**Group selection implemented in Milestone 4.9:** EXS enable-by-type
2 (round-robin), 1 (MIDI-note keyswitch), and 3 (regular CC1/CC2 bands)
now map to Studio's established variation, keyswitch, and controller
articulation systems. The importer preserves group labels and switch
MIDI notes, validates every used group before copying audio, and rejects
missing or duplicate round-robin positions and overlapping keyswitch
notes. Studio's native round-robin counter is per-note rather than
EXS's global group rotation, and its CC switching is discrete at note-on.
Controller-switched instruments initialize in their saved articulation
band. CC2-selected patches do not also apply breath-volume attenuation;
ordinary patches retain normal CC2 expression.
Warnings disclose these differences.

**Not yet reproduced:** irregular controller thresholds, arbitrary CCs,
combined/different group-selection conditions, Logic per-note
Articulation IDs (which are not ordinary keyswitches), tempo/channel
conditions, reverse and one-shot playback, pitch-tracking disable,
sophisticated synth/filter/envelope parameters, reverse or ping-pong
loops, and EXS24/Logic modern extended format variants. Such import attempts fail clearly rather than silently
dropping expressive musical behavior. Wider audio-file resolution,
sandboxed folder grants, big-endian EXS, and real-world file auditing
remain future milestones.

**Source references:** Apple's EXS24 user documentation and archived
Audio Unit sampler technical note; public format-analysis resources
support the binary block metadata offsets. This implementation is
original Swift, not a dependency on third-party EXS parser code.

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
