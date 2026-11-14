# Studio — Garritan Articulation Factory, Milestone 5

Date: 2026-11-14
Branch: `feature/pro-midi-sequencer` (draft PR #10; do not merge automatically)

## Primary sources

- Official **Garritan Personal Orchestra 5 User Manual**, [Directory of GPO 5 instrument patches](https://usermanuals.garritan.com/GPO5/Content/directory.htm) and [Controls and MIDI controllers](https://usermanuals.garritan.com/GPO5/Content/controls.htm).
- Official **Garritan Instant Orchestra User’s Guide**, [PDF](https://wpmedia.garritan.com/wp-content/uploads/2016/04/Garritan_Instant_Orchestra_Manual.pdf), especially printed p. 39 (PDF page 39): **no keyswitches in Instant Orchestra**; pp. 40–42 (GM/GPO expression modes) and pp. 47, 62–64 (Blending Textures controls).
- Existing checked-in `Resources/Articulations/GPO5_keyswitch_catalog.json`, originally extracted from the GPO5 HTML documentation text edition. That earlier extraction contained 86 named keyswitch patch records; it is *reference data*, not an unconditionally trusted MIDI program.
  
## GPO5 Standard-set keyswitch examples

The GPO5 manual explicitly defines **C4 = MIDI note 60**. Studio uses that convention for the `Standard` set; octave numbers are not guessed from the physical piano keyboard.

| Exact GPO5 Standard patch | Keyswitch labels from the owner's manual | MIDI note numbers |
|---|---|---|
| Violin 1 KS | C2 sustain vibrato, C#2 lush forte, D2 sforzando, D#2 détaché, E2 martelé, F2 pizzicato, F#2 col legno, G2 spiccato, G#2 staccato | 36–44 |
| Cello 1 KS | C1 sustain vibrato, D1 tremolo, E1 détaché, F1 pizzicato, G1 spiccato short, A1 snap | 24, 26, 28, 29, 31, 33 |
| Violins 1 KS / Violins 2 KS (reference only) | The **KS Groups** listing documents C2 sustain, C#2 heavy vibrato, D2 grand détaché, D#2 marcato, E2 martelé, F2 pizzicato, F#2 portato, G2 col legno, G#2 sautillé, A2 spiccato, A#2 staccato, B2 sul tasto. A second section-string listing with these *same names* instead documents sustain+short, muted bowing, pizzicato, tremolo, and trills. | **Not auto-armed** until ARIA bank paths distinguish the two |
| Full Strings KS | C0 sustain+short, C#0 muted sustain+short, D0 alternating bow, D#0 upbow, E0 downbow, F0 pizzicato, F#0 muted tremolo, G0 tremolo, G#0 muted half-step trill, A0 half-step trill, A#0 muted whole-step trill, B0 whole-step trill | 12–23 |
| SAM Trumpet Solo KS | C2 sustain, D2 marcato, E2 staccato | 36, 38, 40 |
| Flute Solo KS | C3 vibrato, D3 non-vibrato, E3 flutter | 48, 50, 52 |
| Piccolo Solo KS | C4 vibrato, D4 non-vibrato, E4 flutter | 60, 62, 64 |

Not all libraries/presets share these assignments. The Standard violin, solo cello, section cello, bass and full-string patches have genuinely different mappings; Studio must never impose a generic “all strings KS” table.

**Notation warning:** The GPO5 owner’s manual states that Notation-set keyswitches occupy *different octaves* from Standard, and Notation names are `n-` prefixed. Studio currently does not arm Notation programs because an unambiguous GPO5 Notation note-number reference was not established for all patches. Prior-version documentation is not accepted as proof.

## Important manual ambiguity: never auto-arm these without validation

The GPO5 directory repeats `Violins 1 KS`, `Violins 2 KS`, `Violas KS`, `Cellos KS`, and `Basses KS` in different string sections, with materially different articulation lists. The `Basses KS` name also appears in a choir section. Matching only on basename is unsafe. These names are blocked from automatic factory triggers pending patch-path-specific verification.

`Percussion Accessories KS`, `Snares KS`, and `Timpani 1/2/3 KS` include playable percussion note zones/ranges in the earlier extracted JSON. Those notes must not be repurposed as musical articulation switches without patch-by-patch separation. Their catalog entries remain visible as **references only**.

## Instant Orchestra: NO keyswitches

Printed p. 39 explicitly states that Instant Orchestra contains no keyswitches. Do **not** invent pizzicato/staccato keyswitch maps for this library. Its control scheme includes:
- CC1 Mod Wheel, CC2 Breath, CC11 Expression for sustaining-patch dynamics.
- CC104 for GM (velocity + controllers for dynamics) versus GPO (velocity for attack and CCs for dynamics) expression mode.
- Blending Textures: CC1 and/or CC11 for timbral crossfading, with CC30, CC31, and CC32 controlling layer levels.
- MIDI note velocity and attack behavior depend on the chosen expression mode and instrument family.

Studio exposes CC104/CC30/CC31/CC32 in the piano-roll expression selector and presents these controls as **performance data**, not articulation keyswitches. CC104 and GPO CC102 are discrete on/off values.

## Factory-map behavior

1. The established instrument picker stores the **exact** ARIA library and program path in `Track.garritanProgramID`.
2. `StudioGarritanArticulationFactory` requires the literal `Garritan Personal Orchestra 5` library, a `Standard/` program path, an exact single catalog patch match ending in ` KS`, and an unambiguous list of individual keyswitch labels. It rejects the cases above.
3. On successfully loading a new GPO5 Standard patch, the picker attaches the verified factory `StudioArticulationMap`, only if there is no map or the previous one was an **untouched factory default**. Existing composer-customized maps are never overwritten.
4. The Articulation Manager allows choosing **Load GPO5 Factory** explicitly for a known Standard patch. Clicking Apply marks it user-managed so subsequent instrument changes cannot silently discard it.
5. Named articulation IDs remain separate from their trigger notes. The renderer generates keyswitch notes only when preparing playback, and note assignments remain editable and embedded in the project.
6. When switching an untouched factory map to an unsupported, ambiguous, Notation, or Instant Orchestra program, the picker removes its obsolete automatic triggers. The original reference data and any user maps remain available for manual review.

## Acceptance and limitations

- Unit regression checks: exact note numbers, no Instant Orchestra keyswitches, no Notation guesses, ambiguity/percussion quarantine, clip-level semantic map retention, and project persistence.
- The native GPO5 reference list is based on the owner’s manual, **not** an ARIA live play-through. Verify audible instrument response at the consolidated Mac milestone before stamping the maps as hardware-validated.
- This milestone does not introduce additional sample libraries, commercial dependencies or plug-in assumptions.
