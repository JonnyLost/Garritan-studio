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


## Milestone: installed-bank audit tooling (2026-11-16)
The repository does **not** contain the actual `Personal Orchestra 5.bank.xml` or `Instant Orchestra.bank.xml` files. The GPO5 keyswitch JSON is a **manual-derived partial patch list**, not the full bank. Accordingly no complete program-by-program coverage claim is justified.

Added `scripts/audit_instrument_artwork.py`: a standalone Python standard-library tool that inspects installed bank XML, emits a JSON list of program names and candidate instrument identities, and flags generic/unmapped/overlapping names for review. It defaults to the three GPO5 Standard/Notation and Instant Orchestra paths used by Studio's instrument browser. Run on the Mac after installation:

```sh
python3 scripts/audit_instrument_artwork.py --output instrument-artwork-audit.json
```

The report is a review artifact, **not** an authoritative instrument mapping: name heuristics can misidentify ensembles, nonstandard program naming and XML schemas. Review the report and cross-check the existing `GPO5BankReader` parser before changing production mappings. Avoid committing installed-library files or sample content.

The existing `DAWUI/Sources/DAWUI/Resources/GPO5_keyswitch_catalog.json` contains 86 manual-derived keyswitch patch entries, including separate piccolo, piccolo trumpet, snare, timpani, crotales, glockenspiel, handbells, marimba, vibraphone, xylophone, and tubular bells entries. It cannot establish completeness for the 520 GPO5 or 259 Instant Orchestra programs previously observed at runtime.

Next: run the installed-bank audit, review unresolved program names, and then refine instrument-specific percussion variants and their approved watercolor artwork.
