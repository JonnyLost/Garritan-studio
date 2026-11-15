# Studio Sound Designer — Milestone 3: Conversational Refinement

**Development branch:** `feature/studio-sound-designer-m3-conversational-refinement`  
**Base:** `feature/studio-sound-designer-m2-patch-generation` at `594cff7f`  
**Alpha 1 integration:** untouched; no merge requested or performed.

## Completed implementation

`StudioSoundPatchRefiner` converts follow-up descriptions into **changes to the existing native Synth patch** rather than rebuilding a new patch from factory recipes.

```swift
let generated = try StudioSoundPatchGenerator.generate(
    description: "warm evolving analog pad")
var session = try StudioSoundRefinementHistory(patch: generated.patch)

let preview = try session.refine(
    "Make it darker, slow down the attack, and give it a fuller low end")

// preview.before and preview.patch are complete, validated StudioSynthPatch
// values. preview.changes lists exact layer IDs, controls, before/after
// values; preview.limitations describes approximations.

// A future Sound Designer UI will offer A/B audition, Undo, Redo,
// and Apply. Applying uses the existing UI/ViewModel entry point:
// try projectViewModel.updateStudioSynthPatch(preview.patch, for: trackID)
```

The refiner supports all six native engines (Analog, FM, Wavetable,
Additive, Granular, Physical Modeling) with additive edits to the relevant
parameter values. It uses the existing parameter ranges and exponential
control mappings. Changed parameters are applied via each patch's
validated setter, with the entire result validated before return.

**Invariants and safety:**

- All existing layer IDs, engine types, names, enablement flags, gain levels,
  arrangement and user-edited unrelated controls remain intact.
- Existing MIDI mapping and cross-engine modulation settings/routes are
  preserved verbatim.
- Imported granular audio paths and granular source selection are preserved.
  Refinement never substitutes a sample library, adds a plug-in, or loads files.
- Reverb/mixer sends, track routing, project files and playback are unchanged.
  "Wider" changes native spread or hybrid panning, not reverb.
- Unsupported or no-op instructions produce limitations or typed errors,
  rather than falsely claiming sonic matches.
- Physical Modeling has no universal attack envelope; "slower attack"
  adjusts excitation hardness and explicitly discloses that approximation.
- The entire editor works locally/offline without LLM APIs or network access.

## Preview, comparison and history

`StudioSoundRefinementResult` contains the exact **before/after patch**
and a per-control diff with values and layer identity, plus short limitations.

`StudioSoundRefinementHistory` stores 32 consecutive successful steps
with snapshot-based `undo()`, `redo()`, `reset(to:)`, branching when a
new edit follows an undo, and failure-safe operation. No unsuccessful
instruction can overwrite a sound or truncate the redo branch.

**Important integration boundary:** This milestone implements the native
backend, not an interactive text-input/audio-preview UI. A caller must
explicitly audition and apply the patch with
`ProjectViewModel.updateStudioSynthPatch`; Studio's existing undo system
then handles the corresponding track change. The in-memory refinement
history is independent of project undo and does not silently modify the DAW.

## Verification

- `StudioSoundPatchRefinerTests` exercises natural-language multistep
  changes, unrelated hand edits, six engines, hybrid identity/routing,
  imported sample paths, stereo limitations, physical-model approximation,
  invalid text, bounded history, undo/redo, branch replacement and JSON.
- Dedicated Sound Designer GitHub workflow runs Swift syntax validation,
  macOS debug build, focused tests, whole-project regression suite and
  optimized app build.

## Next milestone

Milestone 4: Integrate the Sound Designer into the lower Synth workspace
with a text prompt, explainable edit preview, A/B comparison, undo/redo,
and an explicit Apply action. Reuse existing DAW history and audio routing.
Audio audition and workflow acceptance should be consolidated with the
Alpha 1 MacBook testing milestone.
