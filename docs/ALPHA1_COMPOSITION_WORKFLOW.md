# Garritan Studio — Alpha 1 Composition Workflow

Status: **implementation target; not yet a validated release**  
Working branch: `feature/stage-acoustics-sync`  
Source baseline: `docs/DEEP_AUDIT_2026-11-08.md` and `docs/INTERFACE_DIRECTION.md`

## Product goal

Make one complete, reproducible orchestral MIDI composing session possible without
switching applications:

1. Create/open a project; select a MIDI or instrument track.
2. Find a GPO5 or Instant Orchestra program in the existing instrument browser.
3. Load it on the selected track without changing another track's plug-in instance.
4. Enter or record MIDI, edit notes, velocity, and CC in the track piano roll.
5. Hear playback; move the instrument on the orchestral stage and adjust Concert Hall wet/dry.
6. Adjust track/mixer volume, mute/solo, and pan.
7. Save, quit, reopen, and recover the same instrument/program, MIDI, stage layout,
   effect state, and audible playback.

A source implementation is **not** proof of these acceptance criteria. The complete
path must be exercised on a Mac with installed ARIA / Garritan sample libraries.

## Existing foundation — retain

- `MainWindowView`: transport, arrangement, workspace navigation, resizable lower
  workspace, optional Inspector and keyboard.
- `VRackView`: instrument-first library browser, filters, preview/load commands.
- `TrackPianoRollView`: piano roll, velocity/CC lanes, quantize and timing offset.
- `OrchestralStageView`: seating templates and Concert Hall positioning.
- `MixerView`: track and master strips.
- `StudioAppearance`: existing theme/icon collections.
- `PlaybackEngine` / `AudioEngine`: **preserve existing tested signal chain**.
- Do not start an interface redesign or replace functioning views to meet Alpha 1.

## Source-level corrections made after the November 8 audit

- Instrument Inspector and Articulation editor commands now use the exact hosted
  track instrument instead of matching only the Audio Unit description.
- Mixer and plug-in insert editor commands resolve the actual effect Audio Unit
  from the track graph; no audio nodes are rewired for these lookups.
- Transport previous/next-bar controls use `ProjectViewModel.seekTo` and are
  disabled during recording.
- Mixer display menu now toggles inserts, meters, and master visibility; Stage
  sends open the existing Stage workspace instead of an empty menu action.
- Misleading mixer remove command and fabricated CPU usage display were removed.

These are **uncompiled source changes** until macOS build/verification.

## Alpha 1 validation gate (single Mac milestone)

- [ ] `swift build` completes on macOS for the feature branch, including DAWUI.
- [ ] App launches and loads ARIA without crashing (use safe generic parameter UI
      when the native ARIA editor is unstable).
- [ ] Two tracks using the same ARIA type open their **own** instrument controls;
      two instances of the same effect type do not open one another's editors.
- [ ] Record or draw notes, adjust velocity/CC, play, stop, jump a bar backward/
      forward, resume from the correct musical position.
- [ ] Stage movement changes audible placement/reverb; a dry zone stays dry.
- [ ] Track and master faders, meters, mute/solo, and mixer display toggles behave
      correctly. Stage shortcut opens the Stage workspace.
- [ ] Save/reopen project and confirm MIDI, instrument states, layout, routing, and
      stage settings are restored.
- [ ] Repeated open/edit/play/save cycles avoid crashes and stuck MIDI notes.
- [ ] Run regression tests; perform a listening pass at the milestone, not after
      every small source edit.

## Outstanding risks — not declared solved

See `docs/DEEP_AUDIT_2026-11-08.md` for full evidence and severity. In
particular: the audio recording input callback and playback timing tap still
need real-time-safe designs; MIDI scheduling and the experimental Core Audio
backend have unresolved concurrency concerns; undo/redo track lifecycle may
desynchronize the graph; project saving remains vulnerable to some failure
sequences; tempo-map scheduling and MIDI export are incomplete.

Do **not** perform speculative render-thread or sample graph rewrites without
focused tests and a macOS runtime. Do not merge this branch without the owner's
explicit approval.

## Defer until after Alpha 1

Score notation, video scoring, expanded MIDI export, sophisticated sends/I/O
mixing, and major UI architecture changes. Keep the instrument-first direction
recorded in `docs/INTERFACE_DIRECTION.md`.
