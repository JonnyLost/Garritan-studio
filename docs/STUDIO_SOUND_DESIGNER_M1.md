# Studio Sound Designer — Milestone 1: Native Description Interpreter

**Branch:** `feature/studio-sound-designer-m1-interpreter`  
**Parent:** `integration/studio-synth-sampler-bridge` (201 factory presets)  
**Integration:** Not merged into the Alpha 1 candidate.

## Purpose

This first milestone converts a musician's words into portable, typed sound-design
intent. The new `StudioSoundDescriptionInterpreter` is pure Swift/Foundation,
deterministic and offline. It does not call Claude, Supabase, a local LLM, or
the audio engine; it does not load or modify a project.

It intentionally **does not build or audition a patch yet**. That is Milestone 2.

## Supported concepts

- **Sound roles:** pad, lead, bass, keys, pluck, percussion, texture.
- **Acoustic references:** strings, brass, woodwinds, voice, bells, percussion,
  noise. The interpreter keeps explicit exclusions separate from requests.
- **Explicit synthesis requests:** Analog, FM, Wavetable, Additive, Granular,
  Physical Modeling. It never invents an explicit engine request when none
  is present.
- **Quality dimensions:** brightness, warmth, attack time, release time,
  movement, metallic character, noise, low end, spaciousness, aggression,
  harmonic complexity.
- **Instructions:** set a 0…1 normalized quality target, or increase/decrease
  the current quality. `create` defaults to absolute targets; `refine`
  defaults to relative changes. Explicit "more"/"less" stays relative.
- **Language:** whole-word phrase matching, short modifier scopes,
  negatives ("not", "without", "avoid"), comparative strength ("a little",
  "much"), and last-mentioned quality precedence.
- **Safety limits:** trims empty requests; limits descriptions to 2,000
  characters. Unrecognized descriptions return an empty intent rather than
  a fabricated patch.

## Example

Input:

> A dark, cinematic string-like pad with a slow attack, warm low
> frequencies, and shimmering metallic harmonics. Something spacious.

Interpretation:

- Role: Pad; family: Strings.
- Brightness: low; warmth: high; low end: high; attack time: long.
- Metallic character, harmonic complexity and spaciousness: high.
- Engine hints: empty, because the user did not name a synthesis algorithm.

Refinement:

> Make it less metallic and a little warmer, with more movement.

Interpretation:

- Metallic character: decrease.
- Warmth: small increase.
- Movement: increase.

The output is a `StudioSoundDescriptionIntent` value. Every field is
Codable, Equatable and Sendable, intended as an input contract to a future
patch designer rather than a direct DSP instruction.

## Implementation boundaries

Source:
`DAWCore/Sources/DAWCore/Audio/StudioSoundDescriptionInterpreter.swift`

Tests:
`Tests/DAWCoreTests/StudioSoundDescriptionInterpreterTests.swift`

No new dependencies, UI surfaces, API keys, model downloads, microphone
permissions, audio graph changes, patch schema migrations, or changes to the
existing preset library.

The feature branch also updates inherited tests that hardcoded the old
factory preset counts. These updates preserve original sound validity and
uniqueness checks while accepting the expanded 201-sound bank.

## Milestone 2 contract

Build a **validated, deterministic patch generator** that maps these sound
qualities and roles to the six existing native engines, selecting at most four
layers and respecting real DSP parameter ranges. Provide an audition/revision
workflow only after generated patches can be validated, serialized and
reliably reverted.

Future conversational language modeling may enhance interpretation, but
offline creation must remain possible. Interpretive language can be
approximate: these controls are meaningful starting points, not promises
of realistic instrument acoustics. Listening and balancing are separate
MacBook acceptance steps.
