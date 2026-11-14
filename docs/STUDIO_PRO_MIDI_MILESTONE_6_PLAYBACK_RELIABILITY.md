# Studio — Milestone 6: Articulation & MIDI Playback Reliability

Date: November 14, 2026
Development branch: `feature/pro-midi-sequencer`
Draft PR: #10 — **no merge performed**.

## Scope and changes

Studio previously translated per-note articulation assignments into MIDI, but a seek past earlier keyswitch/controller events would skip that state. Starting in the middle of a phrase could therefore play its next note with the wrong articulation or expression. In addition, the arrangement playhead could jump visually at the loop end without resetting the audio/MIDI session.

### Deterministic seek-safe preparation

- `StudioMIDISessionPlanner.events(for:tempo:from:until:)` compiles all audible MIDI clips of one instrument track into a **single sorted session**.
- It reconstructs the latest earlier **generated articulation keyswitch**, MIDI CC per channel/controller, program, pitch bend and aftertouch *at the playback start beat*, while not replaying musical notes whose onset is earlier.
- State restoration is playback-only, does not alter notes, note IDs, clip events, articulation labels or project persistence.
- Track MIDI-channel filters and mute states are honored.
- Reconstructed keyswitches have short trigger durations (0.01 beat). Later musical notes and controllers retain exact original timing.
- MIDI commands are deterministically ordered at the same beat: generated switches and controls before musical note-ons. In Core Audio, note-offs are explicitly ordered before channel/CC updates before new note-ons.
- Held-controller release events reaching a trimmed MIDI clip edge are clamped just inside the region instead of being lost.

### Chord and overlapping-voice handling

- Repeated *latching* keyswitches for simultaneous notes sharing the same channel, pitch and beat are deduplicated, avoiding repeated key-on/key-off commands on one chord.
- Held CC articulation actions sharing a channel/controller merge overlapping note durations so the controller resets **once after the last active voice**, not when the first note in a chord or overlapping phrase ends.
- Other controller types, MIDI channels and notes are untouched by a given articulation assignment.
- **Instrument limitation:** simultaneous notes demanding different latching keyswitch articulations on the **same MIDI channel** cannot genuinely sound with independent playing styles on a traditional single-channel instrument. Use separate MIDI channels/ARIA slots for poly-articulation divisi. This milestone does not pretend one channel can maintain two patches concurrently.

### Playback engine integration

- Both the **hybrid Core Audio backend** (including track instruments and V-Rack), and the **legacy AVAudioEngine worker** now consume the same precompiled seek-aware schedule.
- Native analog synth precompilation also uses that shared legacy event stream.
- The independent `MIDISequencer` now keeps its track/sampler inputs so it can rebuild articulation state after a seek or a loop lap.
- `TransportState` emits `.loopWrapped` at the actual audio/MIDI loop boundary (instead of only moving the UI ruler). `ProjectViewModel` stops prior voices, prepares a fresh session from the rebased beat, restarts playback, and acknowledges loop completion. A guard avoids duplicate wraps from stale tap callbacks; overshoot is preserved in the new start position.
- These are **control-thread operations**, not work in a real-time audio callback.
- Note-offs and state from prior laps cannot continue into newly compiled playback after `PlaybackEngine.stopPlayback()`.

## Automated coverage

`Tests/DAWCoreTests/StudioMIDISessionPlannerTests.swift`:
1. Mid-phrase start restores the last keyswitch, CC1 and CC11 without replaying earlier musical notes.
2. CC/program state from an earlier, already-ended clip is restored, but destructive channel-mode messages (CC120–127) are not.
3. A keyswitch at beat zero of a region precedes its note-on.
4. Simultaneous chord notes using the same latching keyswitch generate a single switch.
5. Overlapping held-CC notes release the shared controller only after the final voice ends.
6. Recompilation from loop start rehydrates state on each lap while maintaining beat limits.
7. MIDI channels have independent CC state.
8. Same-sample Core Audio note-off / state / note-on ordering.
9. Held-controller releases survive trimmed clip boundaries.

## Integration and test policy

The dedicated macOS MIDI CI workflow builds Studio and executes regression tests. The sampler workflow runs native DSP, DAW regressions and the Release app build. Keep this draft PR isolated until explicit product-owner approval.

**Mac acceptance still needed at the consolidated milestone:** audible ARIA/GPO and Instant Orchestra playback, seek during sustained notes, fast loop-wrap stability, simultaneous incompatible key switches across independent channels, V-Rack polyphony, long orchestral sessions and tempo changes during playback.

This milestone improves functional loop restarting; **seamless, gapless audio-loop continuity is not yet claimed**, because playback-session rebuild and audio node scheduling remain control-thread operations. A later engine-specific cross-buffer transition may be appropriate after measured Mac audio testing.
