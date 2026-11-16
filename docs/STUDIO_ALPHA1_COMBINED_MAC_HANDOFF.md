# Combined Alpha 1 Mac candidate

Prepared November 15, 2026 (America/New_York). Branch:
`integration/studio-alpha1-mac-candidate-2026-11-15`.

The branch preserves full histories, integrated in this order:

| Source | Pinned head |
| --- | --- |
| Alpha 1 base | 7fded2f9b9947cad12baaa31e8c0584bf4bd8024 |
| #27 project safety | eec22c8cf1eb1dbf5732f43685c1150f34bcab5a |
| #28 synth presets | 3787b60263b0f8d0188f82e626d12c40d17dc86f |
| #29 MIDI M3/3B | ff3d072abcb8079020e2b00896b420797516f175 |
| #26 Picture scoring | 44ac11a4088956726d0174b058de604c7b859849 |

Picture advanced after the earlier readiness audit. This candidate includes cue
navigation/streamers, one-step scored-movie export, and reviewed revision conform.
Its dedicated Picture and consolidated CI passed before integration. All four
histories merged cleanly; shared app commands/lifecycle and view-model
transport/guide-export changes coexist. Existing source branches and PRs remain
unchanged. Do not merge the candidate into shared development before Mac acceptance.

## Automated gate

Use the **Studio consolidated Sampler acceptance** push run for this branch.
It builds the complete package, runs the full Swift suite, builds optimized DAWApp,
and runs sampler/disk, MIDI, Granular and shared-PCM sanitizer checks. Verify the
run is successful and its head SHA exactly matches the SHA used below. Individual
source CI or the reconciliation job alone does not establish combined readiness.

The added `StudioAlpha1PictureRecoveryTests` exercises Picture data through real
save/reopen, retained previous versions and interrupted draft recovery, including
an unavailable movie that must remain a relinkable external reference.

## Launch on MacBook

Requirements: macOS 14+, Xcode/Swift tools (package minimum 5.9), network for package
resolution, and installed/authorized ARIA/Garritan libraries for orchestral tests.
Keep existing music and the normal checkout untouched; use disposable projects.

1. Find the successful combined run and copy its full 40-character head SHA.
2. In `~/Developer/Garritan-studio`, fetch the candidate branch and inspect the
   launcher from that exact commit. Run the commands below, replacing the SHA.
   The launcher verifies the candidate branch still points at it and builds in a
   separate detached worktree. If the branch has moved, stop and select a tested
   head; do not weaken the check.

```sh
cd "$HOME/Developer/Garritan-studio"
git fetch --no-tags origin integration/studio-alpha1-mac-candidate-2026-11-15
candidate_sha=PASTE_FULL_SUCCESSFUL_COMBINED_SHA
git show "$candidate_sha:Tools/alpha1_candidate_mac_launch.sh" > /tmp/studio-alpha1-candidate-launch.sh
bash /tmp/studio-alpha1-candidate-launch.sh "$candidate_sha"
```

The original `Tools/alpha1_mac_launch.sh` remains frozen to the older checkpoint;
it does not launch this candidate. Logs for this launcher are under
`~/Library/Logs/GarritanStudio/Alpha1-FULL_SHA/`.

## First composing acceptance

Record SHA/run URL, Mac/OS/toolchain, device/rate/buffer and ARIA/library versions.
Use a fixed device configuration first (48 kHz / 256 frames if supported).
Mark each item Pass / Fail / Not Tested, with reproduction steps and logs.

- Launch; create/save a disposable project. Add Instrument, Synth, Sampler and
  Audio. Verify existing Rooms/mics, mixer routing and ostinato remain usable.
- Native and multiple ARIA track/V-Rack destinations: notes/chords, future region
  after silence, sustain, CC1/11, articulations/programs, Stop with pedal held,
  seek and restart. Check first notes, releases and stale controllers.
- Record/edit a phrase and audio take. Save/reopen with edited synth state,
  sampler mappings, AU state and audio. Browse all synth families and new
  Additive categories; confirm 201 catalog sounds remain available.
- Close/Quit Save/Cancel/Don't Save; edits during save. After a completed
  60-second recovery snapshot, force-quit the disposable session and recover as
  a new document. Recover a previous version without overwriting the original.
- Import short H.264/ProRes movies; play/pause/seek/loop, offset/cues, float/dock,
  save/reopen and relink. Check Picture guide gain/mute and no doubled dialogue.
  Preview revision conform on a copy; audio/MIDI material must stay unchanged.
- Export WAV/stems and MIDI. Confirm dialogue is excluded from score/stems.
  Test scored MOV export and listen to the resulting file; verify explicit
  dialogue inclusion and alignment.
- Tempo edit, rapid Stop/seek/restart and short loops under representative load.
  Device/buffer changes intentionally pause; resume manually and check cleanup.

Block acceptance for project loss, crash, ordinary playback silence, persistent
stuck/missing notes, unusable drift/dropouts, or broken recording/export. Preserve
the failing disposable project and logs. Existing worker/receiver latency,
loop-transition gaps, native Sampler bend and control-rate metronome/automation
are documented limits; defer broad M3C work. Acoustic synchronization and long
100-lap/rate-change stress follow the basic composing gate.

This is a test candidate. Hardware listening, AppKit dialogs and real ARIA
behavior remain unverified by automated checks.
