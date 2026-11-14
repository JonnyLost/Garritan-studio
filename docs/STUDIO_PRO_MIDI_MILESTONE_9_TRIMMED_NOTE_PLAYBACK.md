# Garritan Studio — Professional MIDI Milestone 9
## Trimmed MIDI regions must stop audible notes and held keyswitches

Date: 2026-11-14
Branch: `feature/pro-midi-sequencer` (draft PR #10, unmerged)

### Problem
The shared session planner already excludes note starts outside a MIDI region and clamps generated held-controller releases, but it previously retained the entire duration of a note starting before the region end. Both musical notes and synthesized held keyswitch notes could continue sounding beyond the clip trim point. That disagrees with an arrangement editor's expectation of a trimmed region and can leak MIDI sound into the following phrase.

### Implementation
`StudioMIDISessionPlanner.events` now creates a session-only copy of each note event and bounds its duration by the remaining region length (`clipEnd - absoluteBeat`). It preserves the source event ID, beat, original note duration, semantic articulation and project model. The existing same-beat ordering of generated articulation commands and musical notes is unchanged. The change applies to Core Audio, the legacy playback/V-Rack path and the standalone MIDI sequencer through the same shared planner.

### Regression tests
Two new tests in `StudioMIDISessionPlannerTests.swift` verify that:
1. An eight-beat original note inside a two-beat region is scheduled only until the region end, while the saved note remains eight beats long.
2. A held keyswitch and its related musical note both stop at a trimmed region end, with no events scheduled beyond the boundary.

### Validation and pending work
GitHub Actions workflows on commit `a9e8f951615ba5fec78160938d63406de8e41325`: Studio Professional MIDI Arrangement run 43619342467 and Studio Sampler native checks run 43619342492. They were pending/running at the time of this handoff; **do not claim a green build until those complete**. Hardware MIDI playback and ARIA testing remain part of the consolidated Mac milestone.

### Next work
The native Standard MIDI File exporter is developed separately under `feature/studio-core-midi-export` (draft PR #6) and is **not** present on this MIDI branch. Its articulation expansion policy must be integrated only after the branches are coordinated: choose default musical-only export versus opt-in rendered keyswitch/controller/program-command export, retain correct same-tick precedence and note-off matching, and cover roundtrip tests. Do not copy the exporter onto this branch or merge any PR without explicit authorization.
