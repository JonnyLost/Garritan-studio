# Garritan Studio Alpha 1 — Mac acceptance results

Use this for the **first combined Studio hands-on test**. All tests should use a **new throwaway project**, not your existing music.

**Frozen test build:** `47f6d887be3a5f781d33fb83e98472f2c343e3a1`  
**Build source:** `checkpoint/studio-alpha1-ci-green-2026-11-14`  
**Mac date:** _fill in_  
**Mac hardware / macOS version:** _optional_  
**Audio device:** _built-in / interface, optional_

Mark each **Pass / Fail / Not Tested**. When a test fails, record exactly what happened. A video/audio device not available is **Not Tested**, not a failure.

| Group | Quick check | Result |
|---|---|---|
| 1. Launch | Studio launches; new throwaway project saves | |
| 2. Track creation | Add Instrument, Sampler, Synth and Audio; no duplicate/missing mixer channel | |
| 3. MIDI | Draw, copy, undo, play, loop and seek a chord; CC1/CC11; no hanging notes | |
| 4. Synth/Modeling | Audition two available native Synth presets and physical modeling when available | |
| 5. Sampler | Map a short owned sample; play it; run Instrument Factory and portable package round-trip | |
| 6. Orchestral | Verify Garritan/ARIA if installed; try an articulation assignment and MIDI export | |
| 7. Ostinato | Pattern follows tempo, start/stop and transport loop | |
| 8. Rooms / mics | Dry path stays audible; hall send and stage depth work; virtual mic change is audible | |
| 9. Mixer | Track volume/pan, mute/solo, sends work on correct tracks | |
| 10. Audio export | Stereo mix, mono mix and selected-track stems contain intended audible material | |
| 11. Save/reopen | MIDI, sampler mapping, synth choice, routing and track state persist | |
| 12. Unsaved edit guard | New/Open cancel does not destroy edited project | |

## Record any failure

**Test number:**  
**Expected:**  
**What actually happened:**  
**Reproduction steps (2–5 short sentences):**  
**Did you hear silence, distortion, clicks, or a stuck note?**  
**Did Studio crash, freeze, or display an error?**  
**Log excerpt (if useful, avoid pasting unrelated private information):**

The launcher writes logs to:

- `~/Library/Logs/GarritanStudio/Alpha1/build.log`
- `~/Library/Logs/GarritanStudio/Alpha1/runtime.log`

**Stop testing immediately** after project data loss, a crash, severe distortion, runaway volume, failed sample package integrity, or repeated stuck notes. Preserve the test project and logs; do not delete or reset development branches.

## Acceptance decision

- [ ] Automated build / Swift tests / DSP sanitizer and stress gates passed on frozen SHA (already verified on GitHub)
- [ ] All critical interactive Mac tests passed
- [ ] No known project-data loss, silent output, stuck notes, or broken exports
- [ ] Outstanding failures documented and fixed on a separate branch, then retested
- [ ] Owner explicitly approves promotion to the shared development branch

**Until all acceptance conditions are met, this is a test candidate, not the stable production build.**
