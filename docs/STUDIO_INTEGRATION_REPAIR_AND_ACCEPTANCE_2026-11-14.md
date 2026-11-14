# Studio consolidation — repair plan and Mac acceptance gate (2026-11-14)

## Preservation and current state
- Staging is `integration/studio-safe-consolidation-2026-11-14`. No change to `main`, `garritan-integration`, or independent source branches is authorized by this checklist.
- `feature/pro-midi-sequencer` is the authoritative M1–M14 MIDI source, including planner-driven musical/performance MIDI export, per-note articulation metadata, expression editing and MIDI import. Original PR #6 is superseded; do not replace the new exporter.
- PR #14 brought the physical-modeling DSP denormal fix; PR #18 brought Ostinato. The Ostinato project's bytewise JSON stability test is fixed on staging using `sortedKeys`.
- Late stereo/mono/multitrack/stems export updates were merged via the guarded Mac CI workflow, PR #15. Its Mac build, complete tests and optimized DAWApp build passed on the rehearsed combined candidate.
- An older combined-build CI failure (`DAWApp.swift` missing `showStudioExport`) was from a staging commit with the menu ahead of the audio-export declaration. On the current staging head both menu and notification declaration exist; rerun complete CI on this exact head before claiming release readiness.

## Unfinished / separate integrations

| Source | Reason not yet integrated | Required acceptance |
| --- | --- | --- |
| `integration/studio-complete-mac-test` | 21 real Git textual conflicts with professional MIDI lineage (many sampler, persistence and piano roll overlaps) | Compare every colliding implementation; retain newer editor/SMF and independent sampler DSP |
| `feature/studio-sampler-native` | 11 real merge conflicts, including sampler DSP and `PlaybackEngine` | Preserve late sampler bug fixes, crossfades, instrument factory and stream reliability without regressing MIDI |
| `feature/studio-core-project-integrity` | Based on older Mac-test branch; conflicts include `ProjectPersistence.swift`, `DAWApp.swift`, `ProjectViewModel.swift` | Introduce save revisions, AU snapshots and unsaved project guards by targeted reconciliation; test legacy project round-trip and audio files |
| `architecture/studio-independence` | 168 commits above old Mac integration, major Core Audio and session/identity refactor | Integrate behind compatibility gates; preserve offline startup, existing .dawproj and Audio Unit/ARIA support, real-time-safe DSP |
| `feature/stage-acoustics-sync` | Git merge rehearsal is clean but isolated CI fails `VRackMicrophoneRoutingTests.testVRackDirectMonitorIsIsolatedAndRestoredInBothAuditionBackends` | Repair mic AU/source graph: direct monitor can sound, but mic bus returns silence at both initial route and unmute; confirm each legacy/shared backend before merge |

Do not fix a conflict by replacing all of `PlaybackEngine.swift`, `ProjectPersistence.swift`, `Track.swift`, `MainWindowView.swift` or `Package.swift` with one side. Verify preserved behavior and compile/test after every reconciliation. A clean Git merge alone is not runtime proof.

## Automated release gate
Run `swift package resolve && swift build && swift test --parallel && swift build -c release --product DAWApp` on the exact updated staging HEAD using macOS CI. All must pass. Additional mic routing, native sampler, audio export, project compatibility and orchestral MIDI tests must pass after inclusion of remaining streams.

## Mac owner acceptance
After full green CI and completion of outstanding integration: use a separate clone; launch offline; create Instrument/Synth/Sampler/Audio tracks; load GPO5, Instant Orchestra, and native synths; verify recording, piano roll (including 6/8 and 7/8), CC1/CC11/pitch bend, articulations/keyswitches, Split/Glue/Mute, and Ostinato; test stem/mono/stereo/MIDI export, importing exported MIDI, stage/reverb/microphones, autosave/project round-trip and AU state; stress playback and check for stuck notes.

This document is a preservation and acceptance register, not proof that unfinished streams are integrated.
