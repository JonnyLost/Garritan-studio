# Studio Synth factory library — Milestone 2

Base: `7fded2f9b9947cad12baaa31e8c0584bf4bd8024` (Alpha 1).
Source audited: `1b3b49c676f331f87a6c62c95a504e98e6725665`.
The nine source-only commits were inspected; only the seven factory libraries
and expanded audit coverage were ported. No branch merge was performed.

| Engine | Alpha 1 | Candidate |
| --- | ---: | ---: |
| Analog | 24 | 34 |
| FM | 32 | 42 |
| Wavetable | 20 | 30 |
| Additive | 16 | 26 |
| Granular | 12 | 22 |
| Physical Modeling | 12 | 25 |
| Hybrid | 12 | 22 |
| Total | 128 | 201 |

All 73 additional recipes come from the source branch; none were invented.
Existing factory recipes and identifiers remain unchanged. The picker manifest
locks all 201 public identities and engine assignments. Categories remain the
existing path level beneath synthesis type; Additive gains Strings and Brass.
No separate subcategory field exists in the current preset models.

The existing Instruments > Synth catalog automatically includes these libraries.
Selection uses a fresh layer identity, remaps modulation/MIDI references, and
loads the complete editable patch on the selected MIDI/instrument track. The
existing track creation and Synth editor workflows remain unchanged. Projects
embed patch data, rather than relying on factory names or external preset files.

Historical exact counts and FM category distribution were obsolete. Hybrid is
not required to contain Additive: validate two to four enabled layers, distinct
engines, safe layer gains, referenced recipe resolution and patch round trips.
Existing malformed parameter, MIDI/modulation, user preset, factory registration,
legacy project and Synth/Sampler bridge tests remain enabled in the full suite.
The new picker gate constructs every native patch and round-trips edited track
state. This does not substitute for interactive picker acceptance.

Performance inspection: factory arrays and the picker catalog are immutable lazy
static data. Enumerating them creates parameter dictionaries, not native DSP or
PCM. Granular factories use procedural sources without imported paths. Hybrid
lookup reuses patch values; runtime instances are allocated only on selection.
Voice budgets remain the existing eight voices per active engine, at most four
layers. No DSP, audio callback, resource cache, MIDI routing, sampler or project
persistence implementation was replaced. No new dependencies or sound algorithms.
Hardware CPU, memory, battery and sonic quality are not validated by this audit.

Validation uses the existing Studio Synth + Sampler Integration workflow, enabled
for the dedicated candidate branch: dependency resolution, complete debug build,
full parallel Swift regression suite, optimized DAWApp build, plus native Sampler,
Granular and shared PCM ASan/UBSan checks. Exact commit/run results belong in the
PR body after CI completes.

## MacBook acceptance still required

- Browse all seven families and their categories; select new sounds on MIDI and
  instrument tracks, open Synth, edit parameters and modulation, save/reopen.
- Check old projects and user presets, Granular imported sample relinking, Hybrid
  editing, live MIDI expression, automation, sustain, overlapping notes and Stop.
- Capture Synth output into Sampler; verify existing sampled instruments, routing,
  shared PCM lifetime, package save/reopen and normal orchestral/AU playback.
- Audition new presets for level, clicks, tails and polyphonic behavior. Measure
  peak CPU/memory and responsiveness with large sessions and four-layer Hybrids.

Keep the PR draft and unmerged pending review and MacBook acceptance. PR #27 is
independent. Main and Alpha 1 must remain unchanged.
