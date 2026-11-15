# Studio Sound Designer — Milestone 2: Native Patch Generation

**Feature branch:** `feature/studio-sound-designer-m2-patch-generation`  
**Starting baseline:** verified Milestone 1 commit `60f9d34b`  
**Alpha 1:** Untouched. No branch merges.

## Deliverable

Studio now has a **native, offline, deterministic patch generator** in
`DAWCore/Sources/DAWCore/Audio/StudioSoundPatchGenerator.swift`.

The existing `StudioSoundDescriptionInterpreter` converts descriptive text
into typed roles, acoustic references and sound qualities. The new
`StudioSoundPatchGenerator` translates that intent into a **normal, editable
`StudioSynthPatch`** using the six original Studio synthesis engines and
the existing factory recipe bank.

No API keys, external models, paid providers, new Audio Units or audio-file
downloads are needed.

### Developer API

```swift
let result = try StudioSoundPatchGenerator.generate(
    description: "A warm cinematic string pad with shimmering harmonics and movement"
)
let patch = result.patch  // StudioSynthPatch: native, validated, Codable
let name = result.suggestedName
```

The result includes a suggested name, a short explanation of its layers,
and limitations when a described quality has only an approximate mapping.

This milestone intentionally produces an in-memory patch. A future UI can
pass the patch to the existing `ProjectViewModel.updateStudioSynthPatch`
workflow for undoable auditioning. **It does not automatically alter any
track or mixer routing.**

### Engine choice

Explicit requests for Analog, FM, Wavetable, Additive, Granular, or Physical
Modeling are respected exactly, with no fifth engine silently dropped.
Implicit selection considers role (pad, lead, bass, keys, pluck, percussion,
texture) and acoustic reference (strings, winds, brass, voice, bells).
A cinematic strings pad can combine Analog, Additive and Wavetable layers;
brass and woodwind references can choose Physical Modeling. Excluded engines
are filtered before a patch is constructed.

### Sound shaping

All actual parameter writes use each engine's native `set(_:for:)`
validator. The generator maps compatible characteristics to:

- Analog: filter cutoff and resonance, amp envelope, LFO, noise, tuning.
- FM: carrier/modulator attacks/releases, ratios, feedback, velocity brightness.
- Wavetable: position, cross-spectrum level, envelope, LFO, tuning.
- Additive: harmonic tilt/partials, spectral evolution, envelope, motion.
- Granular: grain duration, scan, position jitter, pitch, stereo spread,
  envelope, source selection (built-in procedural sources only).
- Physical Modeling: model selection, brightness, body, picking/bowing
  excitation, release, modal inharmonicity and noise where applicable.

A requested evolving sound may also create a small **validated, native LFO
modulation matrix**, with no more than two destinations. Hybrid layers use
moderate gains and four or fewer voices to protect MacBook playback headroom.

The result can round-trip through `JSONEncoder`, a Studio instrument track
and the existing `.studiosynth` user-preset library without a new file format.

### Honest boundaries

- This is a deterministic **musical starting point**, not a perceptual
  sound-matching AI or machine-learning model.
- Acoustic terms such as "strings" and "brass" are interpreted as
  synthesizer timbres; they do not imply sampled realism.
- "Spacious" changes stereo layering and native spread where available;
  it **does not add reverb** or modify Studio's concert-hall bus.
- The physical-modeling engine has no general amplitude attack envelope;
  excitation changes are an approximation and reported as such.
- Refining an existing, edited patch while preserving its other parameters
  belongs to Milestone 3.
- An interactive prompt/preview/history UI belongs to later milestones.
- Listening and subjective factory calibration remain part of a future
  consolidated MacBook test, not a requirement to ship this isolated code.

### Verification

- `Tests/DAWCoreTests/StudioSoundPatchGeneratorTests.swift` exercises
  all six engines and Hybrid routing, perceptible parameter changes,
  exclusions, engine-count safety, acoustic models, portability,
  determinism, and instantiation of native voices.
- The dedicated GitHub Actions workflow checks syntax, the focused
  interpreter and generation suites, full macOS debug build/tests,
  and optimized `DAWApp` build.

### Next milestone

Milestone 3: safe, undoable *refinement of an existing patch*, with
layer-preserving parameter updates, meaningful comparisons, generation
history, and failure-safe restoration of the previous sound.
