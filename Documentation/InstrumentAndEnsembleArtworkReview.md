# Garritan Studio — Instrument and Section Artwork Review

**Status:** 2026-11-16, `feature/studio-gui-refinement`. This is the review inventory of **code identities**, not a verified complete list of all patches in any Garritan library and not a final collection of approved watercolor assets.

The code currently has **76 base icon identities** (including sections, family fallbacks and generic symbols) and **29 distinct ensemble/section identities** composited from those native vector drawings. The same physical instrument or ensemble icon can be shared across different libraries and articulations.

## Solo instruments and base icons already available in Studio

| Family | Current named identities |
| --- | --- |
| Flutes | Piccolo; Concert flute; Alto flute; Bass flute |
| Double reeds | Oboe; English horn; Bassoon; Contrabassoon |
| Clarinets | Clarinet (general / B-flat aliases); E-flat clarinet; Alto clarinet; Bass clarinet; Contrabass clarinet |
| Saxophones | Soprano saxophone; Alto saxophone; Tenor saxophone; Baritone saxophone; Bass saxophone |
| Horns and trumpets | French horn; Trumpet (general); Piccolo trumpet; C trumpet; B-flat trumpet |
| Trombones | Trombone (general); Alto trombone; Bass trombone |
| Low brass | Euphonium (including baritone horn alias); Tuba; Contrabass tuba |
| Orchestral bowed strings | Violin; Viola; Cello; Double bass |
| Orchestral percussion | Timpani; Snare drum; Bass drum; Cymbals; Triangle; Gong |
| Tuned percussion | Xylophone; Vibraphone; Marimba; Glockenspiel; Crotales; Handbells; Mallet percussion (generic); Tubular bells/chimes; Bells (generic) |
| Auxiliary percussion | Tambourine; Maracas; Castanets; Woodblock; Wind machine; Cowbell; Sleigh bells; Mark tree; Ratchet; Gourd percussion; Claves; Cabasa; Vibraslap |
| Other acoustic | Harp; Piano; Celesta; Harpsichord; Organ; Glass armonica |
| Generic/special icons | Brass ensemble; Strings; Percussion; Choir; Synthesizer; Wind family; World family; Orchestra; Generic fallback |

**Important:** Some named variants currently share similar schematic geometry. These are not yet approved anatomical artwork. E-flat and B-flat clarinet identities are not both individually modeled as independent code cases; the general clarinet currently covers B-flat, while E-flat has a separate case. Likewise, baritone horn is currently an alias of euphonium, and cornet is currently an alias of trumpet. These distinctions remain to be refined where physical shape differs.

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
| Percussion | Marching percussion | Snare + bass drum + snare |
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
- Clarinets: A vs B-flat, and additional contralto / extra-low instruments if supported by a real library.
- Brass: Cornet, flugelhorn, baritone horn, special marching brass, contrabass trombone.
- Percussion: Field snare, marching tenors, individual drum-kit components (kick, toms, snare, hi-hat, ride and different crashes), suspended vs crash cymbals, anvil, whip, rain stick, shaker variants and other actual catalog items.
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
