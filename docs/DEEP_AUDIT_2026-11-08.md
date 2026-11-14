# Garritan Studio — source audit (2026-11-08)

Repository: `JonnyLost/Garritan-studio`  
Branch reviewed and modified: `feature/stage-acoustics-sync`  
Base: `garritan-integration`  
PR: https://github.com/JonnyLost/Garritan-studio/pull/1

## Scope and limits

The Git tree was enumerated (84 Swift files and supporting resources at the time of review). Source was examined in the core audio, MIDI, persistence, plugin hosting, transport, project view-model, Garritan instrument-browser, and selected UI/AI/authentication paths. This was a targeted source audit, **not** an exhaustive semantic review of every source line. The reviewer had GitHub read/write access but no macOS compiler, installed ARIA/GPO5 instruments, real audio hardware, or working project build. No build, automated test execution, performance profile, listening test, or runtime crash reproduction was performed. Source checks cannot establish production readiness.

## Architecture snapshot

- `DAWCore/Audio/AudioEngine.swift`: active legacy AVAudioEngine orchestral track graph, panning, gain and shared Concert Hall send/return; per-track metering and transport timing tap.
- `DAWCore/Audio/PlaybackEngine.swift`: per-track and V-Rack Audio Unit hosting, MIDI scheduling, mixed AVAudioEngine / experimental Core Audio backend, audio-clip playback.
- `DAWCore/Audio/CoreAudio/*`: alternate experimental render graph, scheduler, ring buffer, audio clip and metronome renderers.
- `DAWCore/MIDI/MIDIManager.swift`: CoreMIDI endpoints, MIDI 1.0 UMP parsing and output.
- `DAWCore/MIDI/MIDISequencer.swift`: older timer-driven MIDI sequencer. It had been bound alongside PlaybackEngine even without prepared tracks.
- `DAWCore/Audio/AudioRecorder.swift`: microphone input monitoring, audio capture, and active `MIDIRecorderManager`.
- `DAWCore/Plugins/PluginHost.swift`: Audio Unit enumeration, instantiation, preset serialization and loaded plugin registry.
- `DAWCore/Persistence/ProjectPersistence.swift`: `.dawproj` packages containing project JSON and audio files; save, quick save, autosave, load, export.
- `DAWUI/ViewModels/ProjectViewModel.swift`: mutable session, view-model actions, plugin state save/restore, orchestral stage and MIDI track actions.
- `DAWUI/Views/*`: main timeline, instrument browser, stage, articulations, piano roll, mixer and Audio Unit windows.
- `DAWApp/Sources/DAWApp/DAWApp.swift`: application state, project open/save, plugin-state notification bridge, autosave configuration.

## Verified source issues corrected (commits on this branch)

1. Preserve MIDI velocity 0 to represent Note Off, rather than coercing it to velocity 1: `de364f4` — `Models/MIDIEvent.swift`.
2. Record same-pitch notes on separate MIDI channels independently; treat velocity 1 as a valid quiet Note On and keep note-event count updated on retriggers: `75012be` — `Audio/AudioRecorder.swift`.
3. Stage full project saves and recover the preceding package if promotion fails; require audio sources rather than silently omitting missing files; write project JSON atomically: `60f14c2` — `Persistence/ProjectPersistence.swift`.
4. Do not bind an unused second MIDISequencer timer to the same live transport clock as PlaybackEngine: `b05bb71` — `ProjectViewModel.swift`.
5. Add project-save and MIDI velocity regression tests: `21e8696` — `Tests/DAWCoreTests/DAWCoreTests.swift`.
6. Stop the engine before detaching a live track graph, consistent with the existing tested track-create approach; restart after: `a83fdbe` — `AudioEngine.swift`.
7. Honor incoming MIDI channel in track instrument playthrough, filter by selected channel, clamp V-Rack channel, stop treating velocity 1 as Note Off: `cac8883` — `ProjectViewModel.swift`.
8. Decode incoming 14-bit pitch bend with unambiguous offset arithmetic: `03b5a54` — `MIDIManager.swift`.
9. Reject unfinished Standard MIDI File export instead of writing a header-only corrupt `.mid` file: `b82618f` — `ProjectPersistence.swift`.
10. Add MIDI-export refusal test: `a28421a` — `DAWCoreTests.swift`.
11. Drain stale scheduled MIDI events iteratively rather than recursively on render thread: `c9e125a` — `CoreAudio/RingBuffer.swift`.
12. Attempt restoration of the engine and propagate restart errors when track AU loading fails: `e002642` — `PlaybackEngine.swift`.
13. Attempt engine restoration after failed V-Rack AU initialization: `7dd3abb` — `PlaybackEngine.swift`.
14. Mark events consumed in legacy sequencer look-ahead (which previously retriggered overlapping windows): `992ffd4` — `MIDISequencer.swift`.
15. Capture track-level Audio Unit state during save, in addition to V-Rack state: `6c57bb6` — `ProjectViewModel.swift`.
16. Restore saved track-level AU slots even when not identified as a Garritan catalog program: `47d08b3` — `ProjectViewModel.swift`.
17. Eliminate console logging and diagnostic sample scans inside the experimental Core Audio render callback: `1a8d7f7` — `CoreAudio/RenderGraph.swift`.
18. Remove console logging from Core Audio MIDI send path that may run during render: `24a61a3` — `CoreAudio/RenderGraph.swift`. This leaves other real-time-safety issues, including small-array allocation and synchronization, for a separately tested architectural correction.

19. Stop AVAudioEngine during live track and V-Rack AU detachment: `ede8eeb` — `PlaybackEngine.swift`.
20. Remove a deleted track's hosted instrument and plugin registry entry: `2d2507c` — `ProjectViewModel.swift`.
21. Open the precise AU instance assigned to the selected track (rather than the first ARIA plugin of that type) and centralize track unload: `a234fe2` — `TrackHeaderView.swift`.
22. Update the saved instrument slot only after AU graph loading succeeds; release stale host entries: `72d02a3` — `TrackHeaderView.swift`.
23. Decode a new project before clearing the current session, preserving existing instruments on invalid-file failures: `1dec8e6` — `DAWApp.swift`.
24. Release the V-Rack AU host instance on slot deletion: `5fbf806` — `ProjectViewModel.swift`.
25. Reapply live mixer and stage-acoustics parameters after project undo/redo: `51d7c33` — `ProjectViewModel.swift`.

None of these code changes has passed macOS compilation or a device test here; the regression tests were added but not executed.

## Highest-priority unresolved risks

1. **Critical — audio recording writes and allocates on the input tap**. `AudioRecorder.processRecordingBuffer` allocates `AVAudioPCMBuffer`, converts samples, writes `AVAudioFile`, logs and dispatches UI updates from the capture callback (approximately lines 494–576). Disk I/O and allocation can stall real-time capture. Move buffers through a bounded preallocated ring buffer to a dedicated writing worker; measure overruns and dropped frames.
2. **Critical — the active legacy audio timing tap is not real-time safe**. `AudioEngine.installTimingTap` accesses mutable actor-isolated state, calculates clock conversions, invokes a callback that queues work, and creates a main-actor task every buffer (approximately lines 581–598). Refactor to a preallocated, atomically synchronized event queue and a single transport clock.
3. **High — shared MIDI playback state crosses unsynchronized queues**. `PlaybackEngine.processAudioBuffer` queues closures to `midiProcessingQueue` while transport/track management updates occur on the main actor. `scheduledMIDIEvents`, `activeNotes`, `isPlaying`, and instrument dictionaries require a documented ownership and synchronization model. Explicit `DispatchQueue.sync` elsewhere may also stall if called while rendering.
4. **High — experimental Core Audio render graph and ring buffer are not proven thread-safe**. `RenderGraph` traverses mutable track dictionaries in render callbacks while control methods mutate the graph. `RingBuffer` uses plain Swift integers with `OSMemoryBarrier`, not Swift/C atomic operations with documented acquire/release ordering. Do not advertise that backend as lock-free production ready.
5. **High — audio/plug-in graph rebuilding is not transactional**. Stopping during graph changes helps avoid hangs but AU attachment, conversion mixer connections and partial failures can leave attached nodes or obsolete loaded-plugin references. Add cleanup paths and tests for failures and replacement, without changing the proven signal chain at the same time.
6. **High — project-save consistency requires further hardening**. Full saves now stage a replacement, but the rename sequence is not a single atomic crash transaction and quick-save audio file copying is not staged as a unit. Add durable journaling/backups, external-media validation, and power-loss/failure-injection tests.
7. **High — source tempo changes are not fully reflected in transport/sample scheduling**. Data model holds `tempoChanges`, but multiple conversions and clip scheduling calculations rely on a single `tempo.bpm`. A full tempo-map integration and seek/loop tests are prerequisites for accurate scoring.
8. **Medium/high — Audio Unit state reconstruction is runtime-sensitive**. State is stored as property-list data in instrument slots and restoring ARIA relies on asynchronous plugin loading and applying `fullState`; confirm stability, exact patch reloading and editor failure isolation on actual macOS hardware.
9. **Medium — MIDI export remains unimplemented**. It now fails explicitly rather than manufacturing corrupt files. Implement real MThd and MTrk chunks, variable-length deltas, tempo/time-signature meta events, correctly ordered channel events and end-of-track markers, then test against external DAWs.
10. **High — undo/redo track lifecycle is not rebuilt.** Audio parameters are now resynchronized after undo/redo, but history actions that insert/remove tracks do not recreate/destroy audio nodes or hosted instruments. Test and redesign lifecycle reconciliation before relying on undo for track deletion.
11. **Medium — oversized controller/view classes and limited tests**. `PlaybackEngine`, `ProjectViewModel` and `MainWindowView` are large cross-domain modules. Only three Swift test files are present and no `.github/workflows` CI workflow was found. Do not extrapolate scalability to 80–100 tracks without profiling CPU, memory, audio underruns and AU plugin instance costs.

Additional findings: `ClaudeService.swift` stores its direct-service API key in `UserDefaults`; prefer macOS Keychain for secrets. Device MIDI timing uses callback host time rather than original UMP packet timestamps in parts of the ingress path. The implementation includes incomplete/future-marked alternate audio backend paths and unverified UI/editing behaviors.

## Functional-status distinctions

- **Source-present**: Garritan program browser, ARIA AU host code, stage positioning/depth and shared hall, articulation catalog, MIDI clip/piano roll editing surfaces, transport, microphone recording, mixer, project package persistence.
- **Previously user-reported to work**: application launch, Garritan audio playback, audible reverb and adding several instrument tracks. These reports preceded the audit changes and do not validate the new code.
- **Not verified by this audit**: fresh build, complete project roundtrip with ARIA state, multitrack/channel MIDI recording, uninterrupted input capture, Audio Unit editor launch, offline bounce, tempo map and synchronization, high track counts.
- **Known incomplete**: Standard MIDI file export, commercial-DAW-grade timing and recording safety, end-to-end 80–100 track performance qualification.

## Validation gate on the development Mac

1. `cd ~/Developer/Garritan-studio`
2. `git fetch origin && git switch feature/stage-acoustics-sync && git pull --ff-only origin feature/stage-acoustics-sync`
3. `swift build` and `swift test`
4. Run app with existing working Garritan/ARIA plug-ins: play, add and delete tracks, reassign two instruments and test stage reverb routing.
5. Record MIDI on two channels playing identical pitches, include a very soft velocity-1 note and a normal Note Off. Verify note durations and pitch bend.
6. Save/reopen a project with an edited ARIA preset, a V-Rack instrument, an external audio file and an internally packaged recording.
7. Conduct a modest multitrack playback/load test, then profile audio-callback allocations, scheduling jitter and CPU before pursuing 80–100 tracks.

Do not merge the feature branch until build/tests and playback/save roundtrip checks pass. For larger refactors, establish a new dedicated branch and a macOS CI baseline first.
