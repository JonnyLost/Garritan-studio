# Studio — Professional MIDI Milestone 10
## Articulation-safe Standard MIDI File export planning

Date: 2026-11-14
Branch: `feature/pro-midi-sequencer` — draft PR #10, **not merged**

### Why the implementation is separated

The existing native Standard MIDI File format-1 writer and File > Export MIDI command live on `feature/studio-core-midi-export` (draft PR #6). This MIDI workflow branch has **diverged** significantly from that core export branch (GitHub compare reported 280 commits ahead and 213 behind on 2026-11-14). To avoid transplanting unrelated Main DAW, audio, synth and export changes across branches, this milestone adds a pure DAWCore **export planner**. No exporter or UI files were copied from PR #6; no branch was merged.

### Implemented API

`StudioMIDIExportPlanner.messages(for:tempo:mode:)` emits ordered, 480-tick-per-quarter, SMF-ready channel messages without writing chunks or modifying the project.

- `.musicalOnly` (**default**) exports authored notes, channels, CCs, pitch bend, programs, aftertouch and SysEx. It does not bake semantic per-note keyswitch/CC/program commands. Studio project files remain the authoritative store of semantic articulation IDs. A generic MIDI file cannot preserve these custom IDs on its own.
- `.renderedPerformance` compiles the **actual current per-track articulation map** using the same `StudioMIDISessionPlanner` as playback, including documented Garritan Standard keyswitches, explicitly customized maps, note-channel switches, CCs, program changes, and held-controller releases. If a GPO5 Notation map has no configured triggers, **no triggers are guessed**. Instant Orchestra requires expression CCs, not fabricated keyswitches.
- Both modes honor muted tracks/clips, channel filters and trimmed MIDI note durations. Unknown/invalid times and unexpanded clip loops fail rather than emit an inaccurate stream.
- Ordering for coincident ticks: **note-off → state changes (CC, program, bend) → generated keyswitch note-on → musical note-on**; equal-priority events keep stable timeline order. Short note-offs are clamped to the region boundary; original saved durations are untouched.
- 14-bit pitch bend is serialized exactly into data bytes; 7-bit channel messages are validated before output.
- The helper returns standalone channel-message bytes with absolute ticks. The final Standard MIDI File serializer still owns the track header, conductor tempo and meter events, delta-time VLQ encoding, track names, EOF and atomic file writes.

### Tests added

`Tests/DAWCoreTests/StudioMIDIExportPlannerTests.swift` covers:
- default musical-only policy; original semantic metadata unchanged;
- rendered keyswitch-on-before-chord ordering and deduplication;
- rendered CC/program changes and per-note channel remapping;
- trimmed notes, stable same-tick note-off / retrigger ordering, original duration unchanged;
- full 14-bit pitch bend on independent MIDI channels;
- muted track and output-channel filtering;
- rejection of unsupported loops and invalid tempo;
- one held-CC release at the trimmed region boundary, despite overlapping notes;
- triggerless Notation-style maps never invent keyswitch MIDI.

### Required bridge to native exporter (not yet integrated)

When the MIDI and core export workstreams are coordinated **with owner authorization**, update `StandardMIDIFileExporter.musicEvents` to obtain typed, sorted messages from `StudioMIDIExportPlanner` instead of directly iterating `midi.events`. Make `.musicalOnly` the default export setting; add an explicit user choice for `.renderedPerformance`. Use the planner's ordered tick+bytes stream for channel events while retaining the existing conductor, track-name, SysEx length, error-handling, and atomic-write semantics. Cover full SMF byte roundtrip tests after the writer is present. No branch merge was performed in this milestone.

### Remaining gates

- macOS CI must pass on the **final** commit (professional MIDI tests + sampler native/DSP compatibility and Release build).
- Runtime note-off timing, Garritan/ARIA response, program selection and external DAW import require the single consolidated hands-on Mac acceptance milestone.
- Standard MIDI Files do not carry Studio's embedded semantic articulation map metadata. Editable articulation assignments remain in Studio project data unless a future documented interchange extension is added.
- The existing latching-keyswitch channel restriction remains: conflicting articulations cannot coexist on the same MIDI channel in one multitimbral instrument. Divisi requires independent MIDI channels / instrument slots.
