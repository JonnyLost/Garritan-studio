# Garritan Studio — MIDI Scheduling & Concurrency Stabilization

Date: 2026-11-10  
Branch: `feature/stage-acoustics-sync`  
Related: `docs/DEEP_AUDIT_2026-11-08.md`, `docs/ALPHA1_COMPOSITION_WORKFLOW.md`

## Completed source-level corrections

- Introduced queue-owned session activation, sample-rate and playhead-start
  snapshots for the serial MIDI worker. Main-thread stop/pause uses a queue
  barrier to deactivate further MIDI buffer processing before cleanup.
- Moved the MIDI render-callback timing calculation onto the MIDI worker.
  The render callback now submits only numeric buffer position/frame/tempo
  values instead of reading the playback engine's MainActor transport state.
- Added `MIDIPlaybackWindow` to distinguish events before a seek position,
  events due in the current window (including overdue events), and events
  belonging to a future window. Added boundary and overdue-event tests.
- Build the legacy MIDI schedule in a local array, sort it, and publish it
  atomically through `midiProcessingQueue.sync`, matching the hybrid path.
- Hosted instrument registries are snapshotted for the MIDI worker at playback
  start and updated when a track/rack instrument is loaded. Scheduled MIDI and
  note cleanup read queue-owned instrument snapshots instead of mutable UI
  registries.
- Track/rack removal drains the MIDI worker, sends Note Off for notes targeting
  the removed instrument, and clears its worker snapshot before AU detachment.
- Existing prior-pass fixes remain: V-Rack note cleanup on stop, overdue note
  releases, MIDI channel filtering and clamping, and CoreMIDI packet timestamp
  preservation.
- Fixed two pre-existing build errors in MIDIRecorderManager (incorrect
  `pending.channel` member access, now `noteKey.channel`) and unsupported
  `@MainActor deinit` syntax in AudioEngine and TransportState.

## Build and test evidence

GitHub Actions job https://github.com/JonnyLost/Garritan-studio/actions/runs/42804506117
at commit `8ceb63da`: **full app build passed**; MIDI window and channel
filter regression tests executed without failures. Full `swift test --parallel`
failed exclusively in `ProjectPersistenceSafetyTests.testFailedFullSavePreservesPreviouslySavedProject`:
a save with a missing audio file was accepted and overwrote the original
project. This is a separate **project-integrity bug**; preserve its failing
test and fix it in the planned Audio Unit lifecycle/project-integrity task.
A later build/test run is required for the subsequent instrument-snapshot and
legacy-schedule commits in this document. Never claim runtime success until
a Mac with ARIA/GPO5 is tested.

## Remaining risks

1. The optional, experimental hybrid Core Audio backend's periodic worker
   still reads transport/metronome and audio clip state across actor boundaries.
   It needs separate design and runtime verification before enabling.
2. The AVAudioEngine master timing tap still captures mutable engine state and
   dispatches work from a real-time audio callback. Treat that as the next
   audio-callback stability task; moving the MIDI calculation alone does not
   make the complete tap real-time safe.
3. Dynamic Audio Unit loading/unloading during simultaneous recording or
   active playback still requires a macOS stress test with Garritan installed.
4. Live monitoring/MIDI note previews can send directly to track instruments
   from the main actor; these paths do not use the playback scheduler's worker
   snapshot and should be tested for unexpected stuck notes or channel changes.
5. No macOS audio hardware, ARIA, GPO5, or Instant Orchestra playback tests
   were performed through GitHub Actions.

## Consolidated Mac acceptance gate

After CI compiles, test a two-track repeated-GPO5-instrument project:
start/stop/restart, seek forward past a note, back to its start, repeat rapid
note-offs, run a V-Rack route, change the MIDI channel filter, switch/remove
an instrument during an idle state, and verify no stuck notes or wrong
instrument instance. Save/reopen and perform the full Alpha 1 workflow only
once the project-integrity regression is repaired.

Do not merge without explicit approval.
