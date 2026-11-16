# Published Garritan Libraries — Artwork Coverage Milestone

**Branch:** `feature/studio-gui-refinement`  
**Date:** 2026-11-16  
**Status:** source-verified *instrument and preset names*, implemented *first-pass native vector icons*; **not** full installed-bank coverage or final approved watercolor imagery.

## Evidence and limits

The official Garritan product pages list instrument families, selected section program names and ensemble preset titles. They do **not** substitute for the installed `.bank.xml` files: no complete patch-to-artwork assignment is asserted for these libraries.

Official references:
- [Jazz & Big Band 3 — Features & Benefits](https://www.garritan.com/products/jazz-big-band-3/features-benefits/)
- [Concert & Marching Band 2 — Features & Benefits](https://www.garritan.com/products/concert-marching-band-2/features-benefits-2/)
- [World Instruments — Features & Benefits](https://www.garritan.com/products/world-instruments/features-benefits-2/)
- [Instant Orchestra — Features & Benefits](https://www.garritan.com/products/instant-orchestra/features-benefits-2/)

## Newly implemented solo / physical instrument artwork (21)

| Catalog | Physical instrument identities | Note |
| --- | --- | --- |
| Jazz & Big Band | Sopranino saxophone; mezzo-soprano saxophone; curved soprano saxophone; C-melody saxophone; contrabass saxophone; subcontrabass saxophone | Different saxophone bodies; not different articulations of the same instrument |
| Concert & Marching Band | Mellophone; tenor horn; sousaphone; helicon; sarrusophone; roto toms; flexatone | Solo shapes now independent of generic brass/drum icons |
| World Instruments / cross-library | Bansuri; duduk; didgeridoo; bagpipes; mbira; recorder | Represents individual instrument families without inventing specific installed presets |
| World/Jazz percussion and winds | Harmonica; timbales | Both expressly listed in the official catalogs |

**All 21** have named identity rules, VoiceOver descriptions and an initial vector sketch in `StudioInstrumentCatalogExpansionArtwork.swift`. These are schematic drawings and require instrument-anatomy approval before being promoted to finished illustration assets.

## Newly implemented section / ensemble artwork (16)

| Section identity | Representative grouped icon / relevant published naming |
| --- | --- |
| Piccolo section | Three piccolos; `Piccolo Group` |
| Cornet section | Three cornets; `Cornet Group` |
| Flugelhorn section | Three flugelhorns; `Flugelhorn Group` |
| Mellophone section | Three mellophones; `Mellophone Group` |
| Tenor horn section | Three tenor horns; `Tenor Horn Group` |
| Euphonium section | Three euphoniums; `Euphonium Group` |
| Baritone horn section | Three baritone horns; `Baritone Group` |
| Tuba section | Three tubas; `Tuba Group` |
| Sousaphone section | Three sousaphones; `Sousaphone Group` |
| Helicon section | Three helicons; `Helicon Group` |
| Jazz big band | Alto sax + trumpet + trombone, representative only; `Big Band #1` |
| World ensemble | Sitar + bansuri + tabla, representative only; `African Orchestra` |
| Strings and winds | Violin + cello + flute; `Strings Winds Double Octaves` |
| Strings and brass | Violin + trombone + horn; named cross-family arrangements |
| Winds and brass | Flute + clarinet + trumpet; `Soft Winds and Brass` |
| Orchestra and choir | Violin + horn + choir; `Lush Orchestra Octaves and Choir` |

Existing `Full Orchestra`, `Full Strings`, `Full Brass`, `Woodwinds`, `Marching Band`, `Rhythm Section`, `Sax Section` and related group identities continue working.

**Rule:** These icons communicate *category*, not exact sample-layer instrumentation. For a patch with unknown or fantastical name, preserve a generic/family fallback rather than inventing individual players.

## Bundled illustration integration

- Optional approved PNG location: `DAWUI/Sources/DAWUI/Resources/InstrumentArtwork/`.
- Naming: `instrument_<caseName>.png` or `ensemble_<rawValue>.png` (e.g. `instrument_mellophone.png`, `ensemble_mellophones.png`).
- `StudioInstrumentArtworkAssets` selects and caches locally bundled artwork.
- `StudioInstrumentArtworkCard` uses an available approved image; **otherwise** it renders the native SwiftUI vector icon.
- This milestone adds **no approved illustration PNGs**. The image concepts shared in chat are not bundled production assets.
- No app-level network access, audio/DSP/MIDI routing changes, or new commercial dependencies.

## Validation gates

- New `StudioGarritanCatalogArtworkTests`: 21 identity cases, 16 category matchers, preserved solo-vs-section behavior, and asset-key contract.
- Static source audit: 144 unique base identities and 50 section identities; every one has an accessibility label and an icon renderer branch.
- Pending: macOS build/regression CI on the new feature head, 17–32 pt MacBook icon readability, anatomical review and final PNG approvals.
- Run `python3 scripts/audit_instrument_artwork.py --output instrument-artwork-audit.json` on a Mac with installed Garritan banks for real program names. Do not commit sample-library data.
