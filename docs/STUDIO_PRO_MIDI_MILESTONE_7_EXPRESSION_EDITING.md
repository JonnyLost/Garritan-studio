# Studio Professional MIDI — Milestone 7: Expression Editing and Keyboard Workflow

Date: November 14, 2026
Repository: `JonnyLost/Garritan-studio`
Branch: `feature/pro-midi-sequencer` · Draft PR #10 · No merge

## 1. Scope

Bring both MIDI piano-roll workspaces closer to a practical orchestral composing workflow, while preserving existing per-note semantic articulation assignments, MacBook-first performance, per-gesture undo, and the established expression renderer.

## 2. Shared controller-lane editing

The existing `StudioExpressionLaneCanvas` and `StudioMIDIExpressionEditing` are reused by **both** the region-specific and track-wide piano rolls. Four editing modes are available from the expression lane's **Shape** picker:

| Mode | Purpose |
|------|---------|
| Pencil (1) | Freehand interpolation through recorded pointer positions |
| Line (2) | Straight value ramp between the gesture's first and final point, ignoring pointer jitter |
| Curve (3) | Monotonic S-curve (cubic smoothstep): gentle acceleration and deceleration, no overshoot |
| Erase (4) | Remove events only from the selected CC or pitch-bend lane, channel and beat range; click a single grid cell or drag a range |

All modes preserve unrelated notes, keyswitches, other CCs and other MIDI channels. Curve/line overwrites reuse existing grid-position event IDs where possible. Gestures are previewed against the original clip, then committed **once on pointer release** rather than creating a separate undo operation per intermediate point.

Pencil, line and curve respect the **absolute project beat grid**, including trimmed/offset MIDI regions. An optional clip-end bound keeps newly generated expression events within their region. Fractional region starts retain old controller IDs at the clipped grid edge. A global cap of about 4096 sampled grid points per gesture prevents an accidental full-timeline stroke from allocating an unbounded number of MIDI events.

In the track-wide editor, erasing an empty lane will **not** create an empty MIDI clip. Erasing an existing lane with no matching event does not commit a no-op edit.

Binary CC controls (sustain, legato, auto-legato, Instant Orchestra GM/GPO mode) retain discrete 0/127 MIDI values. Pitch bend retains real 14-bit events. Continuous controllers such as CC1, CC11 and Instant Orchestra's CC30–32 blends remain continuous.

## 3. Precision note shortcuts

The two piano rolls share `StudioMIDINoteEditing.nudging` with **no implicit quantization**:

- Left/Right: move selected notes one snap-grid unit. Snap Off uses a 1/32-note (0.125 beat) keyboard increment.
- Shift+Left/Right: move one bar, calculated from the project meter.
- Up/Down: transpose selected notes one semitone.
- Shift+Up/Down: transpose by one octave.
- Delete: delete selected MIDI notes. Escape: clear note selection.
- 1 / 2 / 3 / 4: choose Pencil / Line / Curve / Erase when the CC lane is visible. Unmodified number keys only: Command, Control and Option combinations are not intercepted.

Selection-wide clamping retains chord intervals and note timing offsets at the beginning of a region and MIDI pitch boundaries. For track-wide edits spanning several regions, one safe delta is computed across the whole selection before applying the changes, avoiding disjoint chord timing at boundaries. Non-note events are never shifted, and note IDs/articulation assignments remain unchanged.

Each keyboard nudge submits **one undoable project update**, skipping unchanged nudges at the pitch/time limit.

## 4. Regression coverage

- `Tests/DAWUIWorkflowTests/StudioMIDIExpressionEditingTests.swift`: line/ramp endpoints, ignoring pointer jitter, S-curve shape, selected controller/channel erasure, reverse-direction strokes, single-point erase at fractional region starts, preservation of IDs on overwrites, no-op erase, clip-end bounds, dense-stroke event budget, existing pitch-bend / binary expression behavior.
- `Tests/DAWUIWorkflowTests/StudioMIDINoteEditingTests.swift`: unsnapped rhythmic phrase nudging, global chord pitch bounds, preserving relative timing at region start, not editing CCs or unselected notes, no-op detection, and existing resize/drag/clipboard regression tests.

## 5. Integration boundaries and next validation

These changes are isolated on the MIDI feature branch. Mac CI builds DAWUI/DAWCore and executes the new tests. The native sampler/DSP verification and Release build run in the companion workflow. Do not merge without explicit product-owner permission.

The consolidated Mac composing milestone should verify editor gestures with trackpad/mouse, scroll/zoom positioning, sustained CC1/CC11 curves, note articulation assignments while editing, and interaction with ARIA's actual MIDI instruments. More elaborate MIDI automation tools (Bezier nodes, multi-point region automation and editable per-note MPE envelopes) can be considered in a later dedicated enhancement; they are not implied by this milestone.
