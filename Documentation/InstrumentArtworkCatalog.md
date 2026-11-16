# Instrument artwork identity audit — 2026-11-16

Scope: Code-based review of `DAWUI/Sources/DAWUI/Views/Shared/StudioInstrumentIcon.swift` on `feature/studio-gui-refinement`. **Not** a full GPO5 or Instant Orchestra bank XML inventory.

## Rules
- Each distinct physical instrument/meaningful variant gets a stable identity and matching artwork; patches and articulations share artwork when the physical instrument is the same.
- Cross-library reuse is required for GPO5, Instant Orchestra, future Garritan World Instruments, Jazz & Big Band, Concert & Marching Band, and native Studio instruments.
- Preserve an offline, local small vector track icon and a richer instrument-browser illustration. No online image dependencies.
- Generic family fallback is temporary; unknown program names must be reported in the full catalog audit.

## Existing code coverage
The original code already distinguishes piccolo/concert/alto/bass flute; oboe/English horn; clarinet/bass/contrabass clarinet; bassoon/contrabassoon; trumpet/trombone/tuba variants; violin/viola/cello/double bass; snare/bass drum/timpani; tuned and auxiliary percussion.

## Added in this milestone
Alto and E-flat clarinet; soprano, alto, tenor, baritone and bass saxophones; euphonium. Added distinct name resolution, accessibility labels and first-pass native vector drawings. The drawings are **schematic**, pending visual approval.

## Artwork expansion queue
- Woodwinds: A and B-flat clarinet identity refinements, curved/straight soprano sax, remaining library variants.
- Brass: cornet, flugelhorn, baritone horn, marching brass and other actual bank variants.
- Percussion: concert/field/marching snare, marching tenors, kit pieces, cymbal types, orchestral auxiliary instruments.
- Jazz/band: saxes, brass variants, guitars, basses, drum kits and keyboards.
- World: sitar, oud, erhu, shakuhachi, tabla, frame drums, and all distinct instruments in installed catalogs.
- Native synths: analog, FM, additive, wavetable, physical modeling, modular, sampler and hybrid.
- Other families: strings, keyboards, vocal, world winds and plucked instruments.

## Verification before release
1. Parse **actual** GPO5 and Instant Orchestra bank XML program names and paths; list unmapped/misclassified programs.
2. Add fixtures for ambiguous names (piccolo trumpet vs piccolo; baritone sax vs baritone horn; bass clarinet vs generic bass).
3. Review vector silhouettes at 20–32 px and refine anatomy.
4. Produce individual approved Cinematic Atelier artwork files for larger previews; no generic substitution for specific instruments.
5. Re-run the inventory for each future Garritan library when its metadata is available.
