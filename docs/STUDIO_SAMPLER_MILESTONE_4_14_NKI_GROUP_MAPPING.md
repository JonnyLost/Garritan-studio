# Studio Sampler — Milestone 4.14: Legacy Kontakt group-start safety

**Branch:** `feature/studio-sampler-native`  
**Status:** Code and synthetic regression fixtures committed; macOS verification pending.

## Objective

Never misrepresent a Kontakt instrument's audible behavior when its group-start rules
are visible but have not been translated. Kontakt permits round-robin, keyswitch,
controller-selected, random and compound conditions. A simple sampler that plays
every stored group on every note can sound dramatically different from the source.

This milestone is deliberately **not** a claim of support for Kontakt group start
rules. The proprietary NKI metadata layout is not sufficiently established to
guess mapping from modern Kontakt documentation alone.

## Implementation

- Legacy `K2_Container` inspection rejects recognizable group-start option
  element names and parameter names, including cycle round robin, controller,
  keyswitch and start-criteria fields.
- Explicit unsupported conditions produce a clear `unsupportedMapping`
  diagnostic before any recording is copied into Studio's library.
- Detached sample zones, nested zones or groups, and duplicate mapping values
  are rejected instead of silently losing or overriding instrument regions.
- Existing program/group/zone key and velocity intersections, sustain loop,
  note-off release sample and safe external recording import remain unchanged.
- Synthetic tests cover round-robin, controller and keyswitch condition markers,
  detached zones, and duplicate zone/group settings.

## Validation and next steps

1. Both the macOS Swift build/test/release workflow and native DSP sanitizer
   workflow must pass on the exact resulting commit. A queued run is not a pass.
2. Validate legacy, lawful, unprotected real NKI specimens before adding
   group-start decoding: determine actual serialized names, precedence and MIDI
   behavior; do not infer compatibility from synthetic XML alone.
3. Once verified, translate only unambiguous mutually exclusive groups into
   Studio's existing round-robin and articulation/CC selectors; refuse compound
   conditions Studio cannot reproduce.
4. Signed-macOS sandbox paths, listening comparisons, streaming behavior and
   multi-instrument performance still need the consolidated Mac audition gate.

**Integration:** Frozen Alpha 1 sampler PR #34 and the combined Alpha 1
candidate are untouched; no merge is authorized.
