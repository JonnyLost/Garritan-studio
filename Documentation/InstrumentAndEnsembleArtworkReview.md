# Garritan Studio — Instrument and Section Artwork Review

**Status:** 2026-11-16, `feature/studio-gui-refinement`. This is the review inventory of **code identities**, not a verified complete list of all patches in any Garritan library and not a final collection of approved watercolor assets.

The code currently has **94 base icon identities** (including sections, family fallbacks and generic symbols) and **29 distinct ensemble/section identities** composited from those native vector drawings. The same physical instrument or ensemble icon can be shared across different libraries and articulations.

## Solo instruments and base icons already available in Studio

| Family | Current named identities |
| --- | --- |
| Flutes | Piccolo; Concert flute; Alto flute; Bass flute |
| Double reeds | Oboe; English horn; Bassoon; Contrabassoon |
| Clarinets | Clarinet (general); A clarinet; B-flat clarinet; E-flat clarinet; Alto clarinet; Bass clarinet; Contrabass clarinet |
| Saxophones | Soprano saxophone; Alto saxophone; Tenor saxophone; Baritone saxophone; Bass saxophone |
| Horns and trumpets | French horn; Trumpet (general); Piccolo trumpet; C trumpet; B-flat trumpet; Cornet; Flugelhorn |
| Trombones | Trombone (general); Alto trombone; Bass trombone; Contrabass trombone |
| Low brass | Euphonium; Baritone horn; Tuba; Contrabass tuba |
| Orchestral bowed strings | Violin; Viola; Cello; Double bass |
| Orchestral percussion | Timpani; Snare drum; Field/marching snare; Marching tenor drums; Concert bass drum; Drum-kit kick; Rack tom; Floor tom; Drum kit; Cymbals; Hi-hat; Ride cymbal; Crash cymbals; Suspended cymbal; Triangle; Gong |
| Tuned percussion | Xylophone; Vibraphone; Marimba; Glockenspiel; Crotales; Handbells; Mallet percussion (generic); Tubular bells/chimes; Bells (generic) |
| Auxiliary percussion | Tambourine; Maracas; Castanets; Woodblock; Wind machine; Cowbell; Sleigh bells; Mark tree; Ratchet; Gourd percussion; Claves; Cabasa; Vibraslap; Anvil; Slapstick |
| Other acoustic | Harp; Piano; Celesta; Harpsichord; Organ; Glass armonica |
| Generic/special icons | Brass ensemble; Strings; Percussion; Choir; Synthesizer; Wind family; World family; Orchestra; Generic fallback |

**Important:** All 18 newly separated variants now have independent identities and first-pass vector drawings; several remain visually schematic rather than anatomically approved. A and B-flat clarinets are physically very similar and require subtle scale-accurate artwork. Cornet, flugelhorn and baritone horn are no longer aliases of trumpet/euphonium. Final instrument watercolor illustrations are still pending.

## Section and ensemble artwork implemented (29 code identities)

| Family | Implemented section / ensemble identity | Visual composition |
| --- | --- | --- |
| Strings | Violin section | Three violins |
| Strings | Viola section | Three violas |
| Strings | Cello section | Three cellos |
| Strings | Double bass section | Three basses |
| Strings | High strings | Violin + viola + violin |
| Strings | Low strings | Cello + double bass + cello |
| Strings | Full string orchestra | Violin + cello + double bass |
| Woodwinds | Flute section | Three flutes |
| Woodwinds | Oboe section | Three oboes |
| Woodwinds | English horn section | Three English horns |
| Woodwinds | Clarinet section | Three clarinets |
| Woodwinds | Bassoon section | Three bassoons |
| Woodwinds | Saxophone section | Soprano + alto + baritone saxophones |
| Woodwinds | High woodwinds | Piccolo + flute + oboe |
| Woodwinds | Low woodwinds | Bass flute + bass clarinet + bassoon |
| Woodwinds | Full woodwind ensemble | Flute + clarinet + bassoon |
| Brass | Horn section | Three French horns |
| Brass | Trumpet section | Three trumpets |
| Brass | Trombone section | Three trombones |
| Brass | High brass | Trumpet + horn + trumpet |
| Brass | Low brass | Trombone + euphonium + tuba |
| Brass | Full brass | Horn + trumpet + trombone |
| Percussion | Orchestral percussion | Timpani + snare + cymbals |
| Percussion | Tuned percussion | Glockenspiel + marimba + vibraphone |
| Percussion | Auxiliary percussion | Triangle + tambourine + cowbell |
| Percussion | Marching percussion | Field snare + marching tenor drums + bass drum |
| Vocal | Choir section | Existing multi-singer drawing |
| Orchestra | Full orchestra | Violin + horn + timpani |
| Orchestra | Mixed orchestral ensemble | Flute + cello + horn; **representative**, not a statement of the real patch lineup |

These are local vectors generated directly in SwiftUI; the groups intentionally show multiple recognizable instruments, not a text badge or duplicate solo icon. At 17–32 pt, their exact silhouette legibility still needs Mac testing.

## Name-resolution examples covered by regression tests

- `Violin 1 Solo KS` remains a **solo**; `Violins 1 KS`, `3 Violins Grp 1 KS` become a **violin section**.
- `SAM French Horn Section KS` becomes a **horn section**; `French Horn 1 Plr1 KS` remains solo.
- `English Horn Section` becomes an **English horn section**, never a French horn section.
- `Full Strings Short Bows KS` becomes **full strings**; `Low Strings` and `High Strings` differ.
- `Percussion Accessories KS` becomes **auxiliary percussion**; `Tuned Percussion` differs from `Marching Percussion`.
- `Orchestra Tutti` becomes **full orchestra**, but obscure names like `Big and Bold` are not assigned made-up instrumentation.

## Next families to differentiate — **not yet completed**
- Clarinets: Additional contralto / extra-low instruments if supported by a real library, plus physical-accuracy review of A vs B-flat.
- Brass: Additional special marching brass, plus precise cornet, flugelhorn, baritone horn and contrabass trombone anatomy in final artwork.
- Percussion: Additional drum-kit variants (brush kit, cross-stick, multiple tom sizes), concert vs marching bass drum, china/splash cymbals, whip and rain-stick variants beyond the current slapstick/anvil identities, after bank verification.
- Guitars and other plucked strings, electric and upright basses, electric keyboards/accordion.
- World Instruments: sitar, oud, erhu, koto, shakuhachi, tabla and many additional catalog entries after confirming the actual programs.
- Jazz & Big Band and Concert & Marching Band: patch-specific instruments and ensembles after installation/catalog verification.
- Instant Orchestra: additional **actual** named high/low, layered, action, cinematic and combined patches once the real `Instant Orchestra.bank.xml` is inventoried. Never infer exact instrumentation from poetic patch names alone.

## Required steps before claiming artwork completion
1. Run the `scripts/audit_instrument_artwork.py` reader against the user's installed GPO5 and Instant Orchestra bank XML. The repository does **not** contain those complete banks.
2. Add exact bank-program fixtures and compare Swift resolver outcomes to the bank hierarchy.
3. Approve each anatomically accurate instrument illustration, section lineup, and watercolor asset; poster/contact-sheet images are **concepts only**.
4. Integrate individual optimized assets with native vector fallbacks; keep all resources local.
5. Run macOS CI/build, review 17 pt track header and larger browser artwork, then merge only with approval.

No changes to audio routing, track creation, MIDI, plugin loading, or project data are part of this artwork milestone.

## Milestone: individual instrument variant expansion — 2026-11-16

Implemented **18 new native identities** with accessible labels, name resolution and native vector shapes: **A clarinet, B-flat clarinet, cornet, flugelhorn, baritone horn, contrabass trombone, field/marching snare, marching tenor drums, kit kick drum, rack tom, floor tom, complete drum kit, hi-hat, ride cymbal, crash cymbals, suspended cymbal, anvil and slapstick**.

- The `StudioInstrumentIcon` code now has **94 total base identities**; there are still **29 distinct section/composite identities** in `StudioInstrumentGroupArtwork`.
- `Tests/DAWUIWorkflowTests/StudioInstrumentIconIdentityTests.swift` checks ambiguous clarinet/trumpet/low-brass names, the 18 new variants, and solo-versus-section protections.
- The marching percussion section icon now uses field snare, marching tenor drums and bass drum—not three identical snares.
- `scripts/audit_instrument_artwork.py` has new candidates for all 18 instrument variants, but the actual bank metadata is still missing from the repository. It is an offline classification aid and does not establish total coverage.
- The watercolor concept plate is for **creative review**. Its pixels are not separately extracted, anatomically verified, or checked into Studio. The native renderer is a performant fallback, not the final approved illustration set.
- Changes remain on `feature/studio-gui-refinement`, with no Alpha 1 integration or merge.
