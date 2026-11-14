# Garritan Studio — Professional MIDI Milestone 8
## Owner-manual-verified Garritan patch identity, percussion switches, and Notation safety

Date: 2026-11-14
Repository: `JonnyLost/Garritan-studio`
Branch: `feature/pro-midi-sequencer`, draft PR #10 — **unmerged**

### Sources

All assignments below were reviewed against the official **Garritan Personal Orchestra 5 Directory of Instrument Patches**, https://usermanuals.garritan.com/GPO5/Content/directory.htm. The directory establishes **C4 = MIDI note 60**, and explicitly states that the Notation set uses a different keyswitch octave from Standard with `n-` program names. The previously bundled `Resources/Articulations/GPO5_keyswitch_catalog.json` contains **one** table per patch basename and omits additional manual collisions. It remains an offline reference and has not been mistaken for a bank-identification authority.

### Previously ambiguous strings: resolved by context, never basename alone

The official manual lists **Section Strings** and **KS Groups** with the *same* patch names and different keyswitch meanings. `Basses KS` additionally occurs under **Choir**. These names can now become factory maps only when the actual program ID contains an explicit, distinguishing bank folder: `Section Strings`, `KS Groups`, or, for bass choir, `Choir`. Optional numeric folder prefixes (e.g. `09 KS Groups`) are accepted. Vague `Strings/` or unclassified folder paths **remain unarmed**.

| GPO5 Standard patch | Context | Note positions | Characteristic meanings |
|---|---|---|---|
| Violins 1 KS / Violins 2 KS | KS Groups | C2–B2 (36–47) | Sustains, HeavyVib, Grand Detache, Marcato, Martele, Pizzicato, Portato, Col Legno, Sautille, Spiccato, Staccato, Sul Tasto |
| Violas KS | KS Groups | C2–G#2 (36–44) | Sustains, HeavyVib, Grand Detache, Martele Agg, Martele, Pizzicato, Portato, Col Legno, Spiccato |
| Cellos KS | KS Groups | C1–G#1 (24–32) | Sustains, HeavyVib, Grand Detache, Marcato, Martele, Pizzicato, Col Legno, Spiccato, Staccato |
| Basses KS | KS Groups | C0–G0 (12–19) | Sustains, HeavyVib, Grand Detache, Staccato, Staccato Agg, Pizzicato, Col Legno, Snap Pizz |
| Violins 1/2, Violas, Cellos, Basses KS | Section Strings | The octave varies by family | Separate 12-way sustain/short, muted bow, bow-direction, pizzicato, tremolo and trills bank from the **existing** manual catalog |
| Basses KS | Choir | C1=24, D1=26 | Aahs, Ohs — **not strings at all** |

A program's exact `Track.garritanProgramID` is never replaced with a display name. The factory map records program provenance, and existing user-edited maps continue to be protected from silent overwrites.

### Previously ambiguous percussion: genuine switch notes only

The GPO5 manual mixes actual keyswitch pitches and playable percussion keyboard zones under the same patch heading. The source JSON extracted those notes into a flat table, so previously the safest choice was to block the entire patch. The new curated, **percussion-folder-only** tables include just the real articulation switches:

| Program | Switches | Explicitly excluded as playable notes |
|---|---|---|
| Percussion Accessories KS | C3 (48) single hits, D3 (50) playable trigger rolls | Cowbells, gourds, shakers, tambourine, castanets, triangle, chimes, cabasa and others at A#3 and above |
| Snares KS | C3 (48) single hits, D3 (50) trigger rolls | Snare hits and roll notes G#3–C#4 |
| Timpani 1 KS | C1 (24) hits, D1 (26) trigger rolls | C2–A3 / C4–A5 playing zones |
| Timpani 2 KS | C1 (24) hits, D1 (26) trigger rolls | C2–E3 / C4–E5 playing zones |
| Timpani 3 KS | C1 (24) hits, D1 (26) trigger rolls, E1 (28) prerecorded rolls | C2–B3 / C4–B5 playing zones |

The new definitions use exact note names and stable musical IDs. They are emitted as keyswitch MIDI only when the ARIA program belongs to the matching **Standard** set and a confirmed percussion bank folder.

### Notation set: discoverable, but never armed by guesswork

Studio now looks for the optional GPO5 Notation bank at the conventional macOS installation path (`/Library/Application Support/Garritan/Garritan Personal Orchestra 5/Banks/Notation/Personal Orchestra 5.bank.xml`). It discovers these `n-` instruments separately when installed, with the proper orchestra family filtering.

**The GPO5 owner manual does not establish a complete Notation-set MIDI pitch table.** Studio therefore does not copy Standard keyswitch note numbers to Notation programs. Instead, **Prepare Notation Map…** in the Articulation Manager loads the matching verified Standard *articulation names* with **zero MIDI actions**; the user can enter pitches verified against their installed ARIA Notation patch and save an explicit custom map. There is no automated trigger and no implicit octave-shift assumption. If the Notation path has no verified Standard counterpart, the template is not offered.

### Articulations workspace consistency

The dedicated Articulations workspace now derives the **live** keyswitch reference from the same path-specific factory map that actual playback uses. A selected `KS Groups` violin, for example, will display its Marcato/Martele assignments, not the unrelated Section Strings bowing table. Unverified catalog records remain browsable in reference-only mode, and selecting a different patch cannot play it into the currently loaded instrument by basename alone.

### Tests and acceptance

`Tests/DAWUIWorkflowTests/StudioGarritanArticulationFactoryTests.swift` now covers:
- Path-disambiguated KS Groups versus Section Strings for identically named violins;
- Number-prefixed KS Groups, viola/cello/bass group table sizes and pitch ranges;
- Choir Basses vowel assignments isolated from string bowing;
- Percussion switch-only notes and rejection when the percussion bank folder is missing;
- Notation instrument safety, triggerless labels, original program identity and template persistence;
- Existing Standard patch mappings, Instant Orchestra's NO-keyswitch policy, and user map persistence.

The macOS build and MIDI workflow must pass on the final feature head, alongside the sampler/DSP and Release workflow. **Audible ARIA calibration on the user's Mac remains part of the consolidated Mac testing milestone.** No plugin dependencies or library purchases have been introduced.
