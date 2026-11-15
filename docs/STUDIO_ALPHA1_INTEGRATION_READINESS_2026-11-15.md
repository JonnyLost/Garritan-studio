# Alpha 1 integration readiness — 2026-11-15

Decision: a combined candidate is reasonably achievable today, conditional on reconciliation and one successful combined macOS validation. No compile blocker is demonstrated at the inspected individual heads. This audit did not combine code or establish that the combined tree compiles.

## Verified snapshot

GitHub branch refs were resolved directly; CI conclusions and build/test job steps were inspected rather than inferred from PR descriptions.

| Source | Exact head | Existing successful run |
| --- | --- | --- |
| integration/studio-alpha1-consolidated-2026-11-14 | 7fded2f9b9947cad12baaa31e8c0584bf4bd8024 | [43669741602](https://github.com/JonnyLost/Garritan-studio/actions/runs/43669741602) |
| #27 codex/studio-project-safety | eec22c8cf1eb1dbf5732f43685c1150f34bcab5a | [43722598189](https://github.com/JonnyLost/Garritan-studio/actions/runs/43722598189), consolidated 43722598025 |
| #28 codex/studio-synth-presets-validation | 3787b60263b0f8d0188f82e626d12c40d17dc86f | [43728924293](https://github.com/JonnyLost/Garritan-studio/actions/runs/43728924293) |
| #29 codex/studio-midi-audio-timing-m3 | ff3d072abcb8079020e2b00896b420797516f175 | [43740632907](https://github.com/JonnyLost/Garritan-studio/actions/runs/43740632907), native 43740632943 |
| feature/studio-picture-scoring | 96d96029471f1a472263135547ed7249eb7402e7 | [43717696648](https://github.com/JonnyLost/Garritan-studio/actions/runs/43717696648), consolidated 43717696676, native 43717696697 |

All three PRs remain open drafts, individually mergeable against the unchanged Alpha base. Each consolidated run inspected passed dependency resolution, complete debug build, full Swift suite, optimized DAWApp build, and integration guards. #29 additionally passed MIDI atomic handoff sanitizers. Picture's dedicated run passed; its consolidated run also passed full regression/release validation. These are separate-head results, not combined-head evidence. The connector lists PR-associated commit runs; this is not an exhaustive historical push-run inventory.

Picture compares 53 commits ahead / 0 behind Alpha, with the Alpha SHA as merge base and a net 20 changed files. Preserve its full history; do not take only the final import fix. The three PRs share Alpha as their base and have 16 / 17 / 19 changed files respectively.

## Overlap and reconciliation

The changed-file sets of #27, #28 and #29 have no pairwise intersections.

| Shared file | Changes to preserve | Assessment |
| --- | --- | --- |
| DAWApp/Sources/DAWApp/DAWApp.swift (#27 + Picture) | #27 application delegate, close guard, recovery timer/menus, save/open/exit guards; Picture command menu and shortcuts | Inspected edits occupy separate sections; low apparent textual conflict risk. Verify lifecycle and menu behavior together. |
| DAWUI/Sources/DAWUI/ViewModels/ProjectViewModel.swift (#29 + Picture) | #29 synchronous transport event handling and tempo restart; Picture guide-bus property/init and export suppression | Separate sections; preserve both. Semantic risk at Play/Pause/seek/loop, graph changes and export. |

Picture also adds optional Project.studioPicture state, video models/session/workspace, mixer UI and media/export tests. #27 changes the persistence implementation without changing Project.swift; a clean textual result must still retain Picture fields through ordinary save, backups and recovery snapshots.

No source here changes Package.swift or Package.resolved in its net diff. No new package dependency was identified. Existing requirements: macOS 14+, Swift tools 5.9+, Apple audio/video SDKs, C/C++ toolchain, existing Supabase resolution, and installed/authorized ARIA/Garritan libraries for hardware acceptance. Picture uses AVFoundation; its final head includes the missing DAWCore exporter import fix.

Do not import architecture/studio-independence or the entire synth/sampler bridge to satisfy these PRs: their selected work is already ported. Keep existing planner, AU routing, native DSP, sampler/PCM, automation, ostinato and export paths.

Picture guide nodes attach to the existing main mixer during ProjectViewModel initialization. #29 installs a silent clock source earlier in AudioEngine initialization. No direct edit collision, but confirm the clock still advances during silence and guide playback and survives device changes. Preserve Picture's score/stem export suppression and #29's export clock/capture behavior.

CI's successful "Read-only true Git merge rehearsals" job does NOT prove this combination: its source list excludes #27, #28, #29 and Picture, and it reports conflicts without necessarily failing. No exact combined merge rehearsal was performed in this audit. Source was inspected through GitHub; a local clone was unavailable because shell networking could not reach its proxy.

Picture documentation has stale early-milestone statements saying guide audio uses AVPlayer and scored-movie export is unavailable. Current source and later milestone sections implement a dedicated guide mixer bus and WAV-based scored MOV export. Use current code as authority; repair documentation only when preparing the candidate.

## Recommended sequence — future integration, not authorization to merge

1. Recheck all pinned refs; create a NEW integration candidate from Alpha 7fded2f9. Keep development branches, main and the frozen checkpoint unchanged.
2. Bring in #27 project safety first, establishing save/recovery/exit protection.
3. Bring in #28 presets: independent production library files; retain all 201 IDs and regression checks.
4. Bring in #29 MIDI M3/3B at ff3d072a, including its complete history, C primitives, scheduler, transport and tests. Do not use an earlier M3-only commit.
5. Bring in Picture at 96d96029 last. Review both shared files explicitly; retain lifecycle guards, synchronous transport handling, guide setup/suppression and commands.
6. Inspect the aggregate diff for dropped functionality, compile/test once on the final combined SHA, then freeze that tested SHA for tomorrow.

This ordering isolates the larger transport change before adding the video consumer of its clock. #28 is technically order-independent. No hard dependency among the PRs was found. If Picture alone exposes a blocker, retain it intact and use a separately identified core candidate for first composing acceptance; do not claim Picture integration passed.

## MIDI triage

No verified remaining MIDI issue mandates blocking the first basic composing test. M3B supplies frame-clock scheduling, generation invalidation and old-destination cleanup, with successful individual-head CI. Hardware delivery remains unmeasured.

Block acceptance if ordinary track/V-Rack playback produces silence, stuck notes after Stop/seek, stale notes/controllers after project replacement, crashes, repeatable missing note releases, unusable drift/dropouts, or broken recording/export/save. Verify future first notes after silence and multiple ARIA destinations early.

Defer M3C work: sample-accurate receiver adapters, backpressure, seamless loops, native Sampler bend, sample-timed metronome/audio, tempo-map navigation and acoustic calibration. Worker polling/receiver queues can add latency; loop policy cuts/releases and may leave gaps. Audio/metronome/automation/ostinato retain control-rate paths. Use default AVAudioEngine and a fixed device/rate/buffer for the first session; optional direct Core Audio graph/queue safety remains unfinished. Device/buffer changes intentionally pause; Stop/Play may be needed after an unannounced clock restart. Do not require a broad timing refactor today.

## Integration checklist

- [ ] Pin/recheck source SHAs and preserve development refs.
- [ ] Reconcile shared files without whole-file ours/theirs replacement; retain all added tests.
- [ ] Verify Picture metadata survives save/reopen, previous-version recovery and unsaved-draft recovery alongside AU states and packaged recordings.
- [ ] Confirm 201 synth presets, existing sampler/PCM, Rooms, orchestral routing, MIDI planning and export entry points remain.
- [ ] Validate final combined SHA once: swift package resolve; swift build; swift test --parallel; swift build -c release --product DAWApp.
- [ ] Retain native sampler/shared PCM and MIDI sanitizer gates in the candidate validation. Reuse existing workflow rather than launching all historical branch pipelines.
- [ ] Ensure validation checks out/logs the combined SHA. Arbitrary new branch pushes do not match current workflow branch filters; use a deliberate workflow_dispatch ref if needed.
- [ ] Record final SHA, successful run URL/toolchain and Mac launch command. No combined CI was started for this preparation audit.

## MacBook build and test — 2026-11-16

IMPORTANT: Tools/alpha1_mac_launch.sh is frozen to checkpoint/studio-alpha1-ci-green-2026-11-14 at 47f6d887be3a5f781d33fb83e98472f2c343e3a1. It will build that older checkpoint, not this candidate. Keep it frozen; do not use it to validate the combination.

Fetch the approved candidate branch into a separate checkout/worktree. Verify its full SHA against the recorded successful combined run. Use a new directory and disposable projects, preserving the normal checkout. In that directory:

```sh
sw_vers
swift --version
git rev-parse HEAD
swift package resolve
swift build --product DAWApp
swift build -c release --product DAWApp
swift run --skip-build DAWApp
```

If the complete suite already passed on this exact SHA, avoid repeating it on the MacBook unless a discrepancy needs investigation. Capture build/runtime logs and use docs/STUDIO_ALPHA1_MAC_RESULTS_TEMPLATE.md.

1. Record Mac model/architecture, OS/toolchain, device, rate/buffer, ARIA/library versions. Start at a fixed 48 kHz / 256-frame configuration if supported.
2. Basic composing gate: native Synth/Sampler plus multiple ARIA track/V-Rack destinations; record/edit/play a short phrase, future region after silence, chords, sustain, CC1/11, articulations and programs. Stop with sustain held; seek and restart. No stuck or stale notes.
3. Save/edit/reopen with AU state, recorded audio and edited synth recipes. Check Close/Quit Save/Cancel/Don't Save and edits during save. After a completed 60-second recovery snapshot, force-quit only the disposable session and recover as a new document.
4. Browse every synth family, including Additive Strings/Brass, audition new recipes and one layered Hybrid. Check old/user presets, imported samples, Synth-to-Sampler capture and unchanged orchestral routing.
5. Picture: short H.264 and ProRes clips; play/pause/seek, offset/hit points, short loops, float/dock, save/reopen and missing-file relink. Enable guide audio; verify mute/gain, no doubled dialogue and no guide leakage into WAV/stems. Export a scored MOV from the bounced WAV and listen back.
6. Cross-system smoke: tempo change, recording, short loops and rapid Stop/seek/restart under representative orchestral load. Check device/buffer changes pause safely, then resume manually. Verify audio/MIDI exports. Escalate reproducible failures; longer 100-lap, 44.1/48/96 kHz and loopback latency measurements follow after the basic gate.

Readiness claim: individually CI-green, low apparent textual overlap, credible same-day integration; combined compilation and Mac interaction/listening are still required. No merge, cherry-pick, rewrite, development-branch edit or CI dispatch was performed by this audit.
