# Studio Analog — Part 4 modular patchboard

Branch: `feature/studio-analog`. Native C++17 engine and native SwiftUI;
no additional synthesis libraries, third-party software, plug-in scan or
plug-in installation required.

## What Part 4 enables

- Switch between **Analog** and **Modular** in Studio Analog's native panel.
- Ten first-generation modules: Oscillator 1, Oscillator 2, Noise, Mixer,
  Filter ADSR, LFO, Filter, Amp ADSR, VCA and Output.
- Click the **OUT** jack on one module, then click a compatible destination
  input jack. Audio cables are orange; modulation cables are cyan.
- Source outputs can fan out to multiple destinations. Each input jack
  currently accepts one cable; a new cable replaces that jack's previous
  connection as one atomic edit.
- Select any cable in the bottom bar to set gain (including polarity inversion),
  disconnect it, or return to the factory graph.
- Undo Cable / Redo Cable apply to cable edits **within the current patchboard
  view session**; project-wide undo integration has not been added.
- Every accepted routing is stored in the track's native `studioAnalogPatch`
  with an optional versioned list of typed `StudioAnalogConnection` objects.
  Older projects without cable arrays restore the original factory graph.

## Signal graph contracts

This is a genuine, fixed-module modular signal path: the native graph compiler
enforces port types, a maximum connection count, no duplicate input jacks,
non-finite gain rejection, and no feedback cycles. It requires a source for
VCA audio input and a connection to Output. The C++ DSP renders the compiled
connections; cables are not merely decorative.

The first panel exposes only existing inputs, rather than arbitrarily created
modules or oscillator pitch-modulation inputs. Audio/CV cable gain range in
the UI is -2x through +2x. Arbitrary feedback, new DSP modules, multicable
mixing into one jack, MIDI-as-CV, and CV-to-audio-rate modulation are not yet
supported.

## Safe live reconfiguration

`sa_submit_patch` compiles a full graph on the control thread and publishes
it through one of three preallocated graph slots:

1. The control thread checks that an earlier edit has been acknowledged.
2. It builds a complete graph in a free, non-active slot.
3. It publishes that slot with a release-store.
4. The audio callback acquires the published slot **only at the start of a
   render buffer** and publishes ownership before reading it.
5. The control thread never overwrites active or pending graph slots.

This avoids SwiftUI mutating a render-thread graph and avoids allocation or
locks inside the audio callback. Rapid edits can return **busy**; the UI shows
a message and does not save or render the rejected edit. The caller must
serialize graph submissions (currently the SwiftUI MainActor). `sa_destroy`
must not run while rendering.

The engine currently changes graph topology at a block boundary, **without
an audible crossfade between old and new graphs**. Sudden connections can
still click. Click-free output crossfades, fully generic modules, sample-offset
MIDI, channel-specific controls and broader CC routing are later milestones.

## Verification

The standalone DSP sanitizer test checks successful graph swaps, pending
back-pressure, invalid cycle rejection, and an actual audible-to-silent
signal-path change after rerouting. The Swift test suite checks cable typing,
unique destination ports, routing submission and persistence/legacy fallback.
GitHub Actions builds the macOS app (debug and optimized) and runs the suite.
Physical listening and stage-reverb checks on the user's Mac remain pending.

**Development discipline:** this branch remains in draft PR #2, with no merge
or changes to the baseline ARIA code.
