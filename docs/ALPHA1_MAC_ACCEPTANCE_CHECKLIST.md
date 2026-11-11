# Garritan Studio — Alpha 1 Mac Acceptance Checklist

Status: **automated debug validation passed; hardware acceptance pending**  
Branch: `feature/stage-acoustics-sync` (PR #1; **do not merge without approval**)  
Created: 2026-11-10 (America/New_York)

## Automated validation already completed

GitHub Actions:
- [x] `swift package resolve` on macOS 15
- [x] `swift build` — all application/library targets compiled at commit `67b0ccc0`
- [x] `swift test --parallel` — **37/37** existing XCTest cases passed at commit `67b0ccc0`
- [x] Regression coverage for MIDI window boundaries, channel selection,
  audio capture ring overflow, stereo position, project-save rollback,
  Quick Save, packaged audio preservation, and WAV write/read round trip
- [ ] `swift build -c release --product DAWApp` — new CI step; check latest run
- [ ] **Final commit's** CI status — should be success before requesting Mac testing

Evidence: https://github.com/JonnyLost/Garritan-studio/actions/runs/42941170018

**Not covered by CI:** ARIA custom editor stability, Garritan sample installation,
MIDI hardware input, actual microphone and V-Rack output capture, live
Concert Hall acoustics, repeat plug-in lifecycle behavior, and audible
save/reopen fidelity. The tests cannot substitute for a single Mac pass.

## One-time setup (when you have the Mac)

Use an expendable/new project, not your only copy of a composition. Quit any
previous Studio instance before pulling. Paste this into Terminal:

```bash
cd ~/Developer/Garritan-studio
git fetch origin
git switch feature/stage-acoustics-sync
git pull --ff-only origin feature/stage-acoustics-sync
swift build && swift test --parallel && swift run DAWApp
```

If Swift reports errors, save the exact compiler output. If the repository
switch refuses because of local edits, **do not force reset or delete files**;
preserve the worktree and report the message. No merge is required.

## One consolidated composing session (do not repeat individual tests)

| # | Action | Alpha 1 acceptance |
|---|--------|--------------------|
| 1 | Launch, create a disposable project, select the instrument workspace | No launch crash; interface responds |
| 2 | Load GPO5 instruments on two tracks; use same ARIA plug-in type on both | Both sound and open their **own** correct plug-in controls |
| 3 | Draw notes in piano roll, vary velocity and one expression/CC lane | Notes and controller changes survive playback |
| 4 | Record a few bars from an available MIDI controller if attached | Recorded timing, pitches and note-offs are plausible; no stuck notes |
| 5 | Play, stop, seek ahead/back, restart and toggle solo/mute | Correct notes resume, no hanging notes or unintended other-track sound |
| 6 | Move instruments through stage depth zones 0–5, change pan and Concert Hall send | Dry front/zone 0 remains dry; farther rows have audible hall, and pan works |
| 7 | Add and remove a track insert effect, then change instrument and rack settings | Correct instrument/effect instance responds; hall send remains connected |
| 8 | If available, record a short microphone take and a V-Rack audio take | WAVs are playable, durations match, waveform/levels respond; no silent truncation |
| 9 | Delete a track and undo/redo once | Track graph, instrument and saved settings reappear/leave as expected |
| 10 | Save and Quick Save, quit Studio, reopen project | MIDI, GPO5 program, instrument/effect presets, stage, routing and audio are intact |

### Practical stop conditions

Stop and keep the logs if:
- The app repeatedly crashes (especially while opening the native ARIA editor).
  The generic parameter UI is the known safer alternative; do not repeatedly
  trigger a crashing native editor just to gather more failures.
- Notes remain stuck after stopping, or a removed insert disconnects all sound.
- Audio capture reports an overflow/write error, or save/reopen fails to
  preserve a previous good project.

Write down **one** consolidated pass/fail report and attach the first relevant
crash log/error trace, not many repeated Terminal diagnostics.

## Residual engineering risks (not release blockers *yet* without runtime evidence)

- The **experimental Core Audio backend** still emits Swift 6 concurrency/
  actor isolation warnings. Keep the proven AVAudioEngine backend for Alpha 1.
- The master timing callback retains shared mutable state; source changes
  reduced per-buffer UI dispatch but did not fully prove realtime safety.
- A failed Audio Unit replacement may still require transactional recovery
  in edge cases such as mid-restart device failure; stress on Mac before
  considering a stable release.
- Undo/redo of an instrument *slot edit on an unchanged track* and full
  audio hardware reconfiguration remain limited versus structural track undo.

## Alpha 1 decision

Passing CI means **ready for a controlled Mac acceptance pass**, not Alpha 1
released. After the checklist passes once, record the outcome, decide on any
critical regression fixes, then seek explicit approval before merging PR #1.
