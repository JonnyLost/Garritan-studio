# Cinematic Atelier — production artwork plan

Status: **implementation foundation**, not an approved image-asset collection.

## Visual direction
- Inspired by the user's approved artwork: expressive ink engraving, restrained watercolor, parchment/copper details, midnight blue and muted crimson.
- All artwork is bundled locally; no runtime web downloads or commercial artwork dependencies.
- Functional surfaces (Piano Roll, waveform, meters, automation and mixer faders) remain clear and low-texture.
- Instrument-specific anatomy takes priority over family-level decoration. Piccolo ≠ concert/alto/bass flute; concert snare ≠ marching snare; each distinct physical instrument must be reviewed.
- No use of copyrighted album-cover images as app assets without explicit selection and source rights confirmation.

## Asset tiers
| Tier | Usage | Production requirement |
| --- | --- | --- |
| Track | 20–32 pt | Native SwiftUI instrument silhouette, legible at 1x and 2x |
| Browser | ~160–320 pt | Detailed approved instrument illustration, isolated subject, local transparent artwork |
| Templates | 16:9 and square cards | Original ensemble illustration and alternate crop; artwork should not contain embedded labels |
| Workspace | Flexible panel | Original room, stage, sampler, synth, reverb and microphone illustrations, independent of controls |

## Implementation
- `StudioInstrumentIcon.swift` already supplies local vector drawings and instrument-name resolution.
- `StudioInstrumentArtworkCard.swift` is the reusable, accessible, offline artwork surface for instrument previews. It uses the same resolver and adapts to narrow panels. It is **not** a final watercolor asset.
- `VRackView.swift` now uses this shared card for its selected-instrument preview.
- Final approved image assets are **not** present in the repository. Future artwork integration must use named local resources and provide the vector fallback when an individual illustration is absent.

## Remaining asset families
1. Template Manager: Full Orchestra, Chamber Orchestra, String Orchestra, Film Scoring, Hybrid Cinematic, Electronic, Band Recording, Mixing/Mastering, Blank Project.
2. Instruments: GPO5/Instant Orchestra distinct instrument inventory, percussion variants, saxophones and wind variants, world and band expansions.
3. Stage/Rooms: orchestral stage, room types and acoustic environment illustrations.
4. Microphones: XY, ORTF, spaced pair, Decca Tree, surround and actual mic capsule layouts; accurate schematics are distinct from decorative illustrations.
5. Native instruments: Sampler, Analog, FM, Additive, Wavetable, Physical Modeling, Modular Synth.
6. Reverb, effects and mastering: restrained illustrations for discovery/empty states only; never behind active meter or automation controls.

## Release gates
- Generate and approve each **individual** original asset, not just a contact sheet.
- Verify physical instrument accuracy and variant mapping.
- Export appropriate resolutions and local resources; confirm licenses/ownership.
- Inspect small MacBook window sizes, contrast, VoiceOver labels and GPU/CPU impact.
- Compile and smoke-test the integrated GUI on macOS; no merge into Alpha 1 until verified.
