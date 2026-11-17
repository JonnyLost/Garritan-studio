# Studio Auto Sampler — Audio Unit capture milestone 1

**Branch:** `feature/studio-auto-sampler-au-m1` (based on the combined Alpha 1 Mac candidate)
**Status:** Implementation proposed; macOS CI and on-device plug-in capture are acceptance gates.

## First working slice

Open a Studio Sampler track, select **Edit Mapping → Auto Sampler…**, pick a registered **Music Device Audio Unit** and, optionally, one of its published factory presets. Select Quick / Standard / Deep coverage and set note-hold and release times. Capture writes WAV takes, maps them with the existing `StudioSamplerInstrumentFactory`, then saves a standalone `.studioinstrument` bundle. The resulting patch can be loaded on the track immediately or opened from the library.

The new `StudioAutoSamplerCapture` deliberately reuses:

- `StudioSynthSamplerCapture.Options` for bounded note/velocity schedules.
- `StudioSamplerInstrumentFactory` for zone/key/velocity mapping and library-owned copies.
- `StudioSamplerInstrumentPackage` for a portable, integrity-checked instrument.

No changes to `PlaybackEngine`, live instrument routing, native DSP, or project format.

## Safety and constraints

- Capture instantiates **a separate AU** in its own `AVAudioEngine` with manual offline rendering. It does not read or overwrite the state of an AU on the user's current project track.
- First milestone supports **AU Music Device instruments only**. Effect plug-ins and generic AU MIDI effects are not instrument sources.
- The source AU must permit manual/offline rendering. If not, capture fails visibly rather than silently substituting a misleading instrument. Real-time bounce is a later milestone.
- Only **factory presets declared by the AU** are selectable. User-created AU patches, custom state import, and embedded plug-in editor support remain future work.
- Captured samples approximate a sound; they do **not** transfer source synthesis, parameter automation, pedal behavior, modwheel morphs, legato rules, or multi-output routing. Complex expression sampling will require explicit additional dimensions and a mapping/data-model review.
- Every requested root note must return non-silent, finite audio. Unsupported ranges may fail the run; custom key ranges and partial-range policy are follow-up work.
- Capture happens in a detached utility task, not an audio callback. Cancellation is checked between and within takes. Temporary raw recordings are deleted when a run ends.
- The package is independent for playback, but the composer must respect the original plugin/sample-library license. Some commercial content forbids automated sampling or redistribution.

## Acceptance gates

1. macOS Swift debug/release build and test suite pass on the branch/PR.
2. A known built-in AU Music Device can be discovered, instantiated, captured, saved, reopened, and played through the native sampler.
3. Failure from an unsupported or non-offline AU presents an actionable message without altering any live track.
4. Confirm cancellation and library cleanup on an actual Mac.
5. Confirm capture of a third-party factory patch for which sampling is contractually permitted, including note-off tails.

## Next milestones

- External MIDI + audio input capture and real-time AU fallback.
- In-host AU editor / custom AU state and program capture (including Garritan when supported).
- Configurable keyboard/velocity ranges, silence-skip rules, progress reporting and resume.
- Automatic loop suggestions, optional release/round-robin capture, and CC1/CC11 expression layers after renderer and package format checks.

## Milestone 2 — capture a configured sound already loaded in Studio

The Auto Sampler sheet now offers two source modes:

1. **Configured in Studio**: choose an Audio Unit already playing on a track or a V-Rack slot. The source's current plugin state is serialized using Studio's existing `PluginHost.savePreset(pluginID:)` (via `fullStateForDocument` / `fullState`), using the exact plugin instance ID held by `PlaybackEngine`. The captured property list is bounded and prevalidated, then restored onto a **newly instantiated** AU Music Device in the offline graph. No live AU is replaced, reset or bypassed.
2. **Installed Audio Unit**: retain the original default/factory-preset workflow.

When a loaded source has no serializable state, capture stops with a visible error instead of rendering the wrong default sound. The native package receives only PCM audio and mapping; plugin state is deliberately omitted. Test preflight rejects invalid/oversized state and factory-preset/state conflicts before plugin instantiation.

### Current limits

- Configured sound capture depends on the source plugin correctly implementing Audio Unit state serialization and restoration, and on supporting offline rendering. Real-world Garritan ARIA compatibility is still **unverified**.
- Multi-timbral Garritan programs may require recording from a selectable MIDI channel and/or a dedicated program-select sequence. This milestone sends notes on **MIDI channel 1** only. A channel selector is a separate follow-up.
- A plugin editor can still be opened on its original Studio track/V-Rack. Auto Sampler does not host a second editable plugin window; it copies the configured AU state just before capture.
- Only installed licensed resources remain accessible to the temporary source plugin while sampling. Portable native packages cannot carry or grant licenses.
- Save/render behavior and live AU state fidelity require macOS CI and a hands-on hardware/plugin test before calling this production-ready.

## Milestone 3 — multitimbral MIDI channel and custom key coverage

The Auto Sampler sheet now includes a **Source MIDI channel** selector (1–16).
This selects the MIDI channel for both note-on and note-off; per-take all-sounds-off
(CC120) and all-notes-off (CC123) are sent only on the chosen channel. Unrelated
channels are not intentionally reset by the MIDI messages. The **temporary**
plugin instance still receives AUAudioUnit.reset() and AVAudioEngine.reset()
between samples, so any plugin-specific reset behavior should be checked on Mac.

For an ARIA multitimbral setup, choose the loaded V-Rack or track instance,
select the channel corresponding to the desired ARIA slot/program, then capture.
There is no MIDI program-change override in this milestone: **the existing
plugin's configured state must already contain the desired programs**.

An optional **Custom note range and sampling interval** setting enables:

- Lower and upper MIDI notes (0...127), displayed as note name plus MIDI number.
- Root-note spacing: 1, 2, 3, 4, 6, 12, or 24 semitones.
- Always capture the requested highest note even when the spacing does not
  divide the range evenly.
- Optionally clamp the playable region of the finished native sampler
  to the selected low/high notes. The original factory key/velocity partitions
  stay intact and the original plugin/track mapping is never changed.
- Automatic plan validation: up to 128 samples total across velocity layers.
  Invalid configurations disable Capture before any plugin is loaded.

When custom mode is off, Quick, Standard and Deep retain their previously
defined root notes, velocity arrays, and *full-keyboard* sampler mapping.

The capture engine takes the plan by value, sends the selected zero-based
Core Audio MIDI channel, and uses the existing isolated offline AVAudioEngine,
native factory and package writer. It does not modify PlaybackEngine,
StudioSamplerDSP, or the user's live project routing.

### Remaining acceptance

1. macOS debug/release build and XCTest pass for this PR.
2. Test independent programs loaded on separate ARIA MIDI channels. Verify
   selecting channel 2 actually samples ARIA slot 2, and does not change slot 1.
3. Reopen a native custom-range capture and verify out-of-range keys are silent
   when the clamp option is enabled, with proper notes at the boundaries.
4. Verify AU state is preserved in the isolated plugin instance across repeated
   resets and that sustain/release behavior matches the source.
5. Honor the source instrument's license. Some commercial sample libraries
   prohibit resampling or redistribution even of derived WAV recordings.

**Still not included:** MIDI program-change selection, per-channel controller
snapshots, automatic silence-skipping, round robins, looping, real-time fallback,
or a production-tested ARIA integration.

## Milestone 4 — conservative sustain loops and native crossfade markers

**Capture UI:** `Find sustain loops automatically` is enabled by default
and can be switched off. If it finds reliable sustain regions, Auto Sampler
adds editable non-destructive `loopStartFrame`, `loopEndFrame`, and
`loopCrossfadeFrames` to the captured native Sampler patch. The original
WAV file bytes remain unchanged. The existing Studio Sampler playback engine
and waveform loop editor already understand the markers.

**Method:** after the offline Audio Unit rendering engine stops, analyze each
temporary WAV independently on the worker task:

1. Require at least 0.8 seconds of held note and readable mono or stereo PCM.
2. Measure bounded RMS windows at 25% and 75% of the held segment. A strongly
   decaying, nearly silent, or abruptly growing sustain is **not** auto-looped.
3. Call the existing `StudioSamplerLoopFinder` on only the middle 25–90% of
   the *held* segment, excluding the attack and the recorded note-off tail.
4. Require a much stricter normalized waveform mismatch than the interactive
   waveform-editor suggestion: at most 0.10, not the editor's 0.50 threshold.
5. Reuse the finder's constrained crossfade (at most 256 frames), and apply
   suggestions to the correct key **and velocity partition**. Release-trigger
   zones are excluded.
6. If no reliable match is found, silently retain the unmodified one-shot zone
   and report how many candidate loops were accepted/skipped.
7. Apply native mapping and portable packaging as before. No live track, DSP
   graph, or source Audio Unit is changed.

**A distinction:** the loop markers allow sustained notes to play for longer
without requiring longer held-note recordings. Milestone 4 does **not**
truncate WAV files or independently model the source plugin's note-off tail.
Therefore it does not yet guarantee smaller disk use or completely natural
release behavior for all instruments. The existing sampler envelope and loop
playback still determine note-off behavior; this needs listening tests.

### Added tests

- Deterministic synthesized sustained sine-WAV successfully gains a loop,
  nonzero crossfade, valid patch, and serializable markers without modifying
  source bytes.
- Short, decaying WAVs are left one-shot.
- Velocity partitions each receive the correct loop markers; release-trigger
  recordings never get sustain loops.
- Swift syntax CI parses new source/tests on Linux; macOS `swift test` is
  required to execute AVFoundation tests.

### Acceptance gates

1. macOS debug and release build and full XCTest pass.
2. Listen to loop transitions on sustained organ/synth/woodwind/string samples,
   including stereo and modulation-rich sounds; ensure clicks/pumping are not
   introduced.
3. Confirm the loop ends strictly before note-off and cannot include recorded
   release content.
4. Reopen exported `.studioinstrument`, review loop markers in the Sampler
   editor, and compare with the original plugin.
5. Confirm percussive, pizzicato, rapidly decaying and short sounds remain
   unlooped; test cancellation with many velocity layers.

**Pending:** loop audition, automatic trimming/disk-size reduction, release
sample extraction, and broader expression-aware capture.

## Milestone 5 — optional recorded note-off release samples

Auto Sampler can now capture **natural note-off tails** as independent
`StudioSamplerFactoryTake(releaseTrigger: true)` recordings. The Sampler's
existing release-trigger dispatch already plays the appropriate recording
when MIDI note-off arrives, honoring the held note's root-key, velocity
partition and articulation. No native DSP or live audio routing was changed.

**Capture workflow:** select **Capture natural note-off release samples**
(default OFF, to avoid doubling storage). Auto Sampler continues to record
each MIDI note through its sustain and note-off duration in a temporary WAV.
Only after the separate offline AU engine stops, a bounded, block-by-block
extractor copies audio starting at the **exact sample frame where note-off
occurred** into another WAV. This preserves the source plugin's actual
released sound rather than applying a fabricated generic decay.

- Preserves mono/stereo format and the current capture sample rate.
- Tests the early 150 ms of each release for audible energy and skips
  effectively silent tails; noncaptured releases remain ordinary sustain
  zones. Composer can disable the feature entirely.
- Maps successful release takes through the existing Instrument Factory,
  which has separate key/velocity partitions for release triggers.
- Leaves the original complete capture WAV untouched, including any existing
  auto-loop crossfade markers on sustain zones. Release zones have no loops.
  Release zones receive a non-destructive 256-frame fade-out marker at the
  end of their captured tail to avoid clicks at the recording boundary.
- The native `.studioinstrument` package includes actual release PCM,
  without embedding the source Audio Unit binary or serialized plugin state.
- Reports accepted and skipped release recordings in the Auto Sampler sheet.

**Bounded resources:** the maximum possible zone count is 128; when release
capture is enabled Auto Sampler refuses plans with more than 64 held
note/velocity recordings *before* instantiating any plugin. The option is
opt-in, so previous capture behavior is preserved for existing composers.
Temporary release WAVs are cleaned with the capture staging directory.

**Added tests:** synthetic stereo recording extraction at the exact note-off
frame, unchanged original WAV bytes, release-zone mapping through the native
factory, save/reopen of a self-contained Studio instrument, silence rejection,
and preflight rejection of a potentially oversized release-enabled capture.

**Caveats and acceptance gates:**

1. The macOS CI build and AVFoundation XCTest suites must pass.
2. Confirm the extracted tail audibly blends with the Studio Sampler envelope's
   note-off fade and doesn't double natural plugin release on held notes.
3. Test Garritan ARIA multitimbral programs and realistic note-off transients;
   some instruments have delayed key-release noises, which an early energy
   gate may reject. Longer source releases may require the existing
   Release Tail duration control (up to 3 seconds).
4. Verify release zones on percussion, pizzicato and short percussive samples
   do not add unwanted tails.
5. Test cancellation, disk-space errors and packaging cleanup on macOS.

**Not yet included:** custom note-off articulations/legato samples, recording
CC1/CC11 expression dimensions, round robins, hardware/real-time capture,
batch resume, or automatic memory/disk compaction.

## Milestone 6 — CC1 orchestral dynamics and CC11 expression reference

The Auto Sampler sheet now offers two mutually exclusive **Source dynamics**
capture modes:

- **Velocity layers (default):** remains the existing MIDI velocity capture.
  The source's preset state and CC11 level are preserved by default. Optionally
  send a composer-selected **source CC11 reference** before each note; this
  level is baked into the resulting PCM.
- **CC1 dynamics:** records each musical key with **fixed note-on velocity**
  (default 100), independently sweeping CC1 through two or four dynamic
  layers (Standard and Deep coverage). Uses the **native sampler's existing**
  `cc1Crossfade` playback and `dynamicsCC1` state to morph continuously
  between the recorded source timbres. CC11 is set to a configurable capture
  reference level (default 127). The output sampler's own CC11 starts at
  127 and is independently adjustable by MIDI, so a chosen capture
  attenuation is **not** inadvertently applied twice.

**Exact crossfade alignment:** Studio's current DSP interpolates according
to the midpoint of each zone's assigned velocity interval, **not the raw
velocity label used to build the zone map**. The expression capture planner
therefore sends the appropriate zone-center CC1 to the source plugin:
Standard map [64,112] uses source CC1 [45,108]; Deep map
[32,64,96,120] uses source CC1 [25,65,95,118]. This deliberately matches
the existing native crossfade without editing native DSP, project format,
or the portable .studioinstrument version.

**Precise capture order:** Each take uses the isolated AU Music Device's
selected zero-based MIDI channel. First flush/reset voices, then program
CC1/CC11 (as applicable), render and discard about 50 ms of offline audio
to settle controller smoothing, then send note-on at the chosen fixed
velocity and record the held/released note. Only the attack onward is
written to WAV. Existing loop analysis, key coverage and instrument
package creation continue unchanged. Source controller values do not
change any live Studio Audio Unit.

**Guardrails:** A CC1 capture must contain 2–8 dynamic layers. Quick mode
(one layer) is not eligible. **Natural release-trigger recording is disabled
in CC1 mode**, because Studio's existing release-zone dispatch chooses
by incoming MIDI velocity while CC1 layer crossfading chooses by the
current CC1 position; combining them would select a potentially
mismatched release sound. It will be supported after an expression-aware
release design. Existing velocity-mode release capture is unchanged.
The patch stores only WAV data and the native zone/CC mapping, not AU
state, external library metadata, or source license data.

**What this is not:** Capturing at a selected CC11 reference plus exposing
live CC11 as a gain/expression control is **not a two-dimensional sample
grid for CC1×CC11**. An Audio Unit that uses CC11 to alter timbre as well
as loudness will not have that continuously variable timbre reproduced
by native playback; additional expressive axes require a sampler-format
and DSP design. Crossfading captured CC1 timbres is an approximation
of the original synthesis, not a byte-for-byte recreation.

**New tests:** ordinary velocity mode backward compatibility, computed
native crossfade centers and fixed source note-on velocity, CC11 reference
behavior, mapped patch serializable state, rejection of one-layer CC1
capture, release-mode conflict, and source configuration validation.

### Outstanding gates

- Full macOS debug/release build and XCTest, plus Audio Unit capture on
  an actual Mac, are mandatory before including this PR in Alpha 1.
- Listen for unnatural CC1 crossfades and compare source vs Studio at low,
  medium and high dynamics, including ARIA strings, brass and woodwinds.
- Verify real CC11 volume/expression automation does not produce double
  attenuation; test source instruments that internally use both CC1/CC11
  for distinct timbral purposes.
- Validate controller settling, disabled release samples, and reliable
  package reopening with AU-hosted custom preset state intact.

## Milestone 7 — explicit Audio Unit keyswitch articulation capture

A new opt-in Auto Sampler section records **Sustain** and one named
alternate source playing technique (default **Staccato**) from a single
Audio Unit. The composer supplies each source keyswitch's actual MIDI
note number; Studio **does not infer** Garritan or third-party plug-in
keyswitch conventions. Source switches are transmitted as momentary
note-on/off events to the isolated AU, after the per-take reset and
before CC1/CC11 programming and audible note capture. They are not
recorded as musical notes or included in the resulting WAV.

The native Instrument Factory already supports articulation-labeled
takes and generates portable `StudioSamplerArticulation` definitions,
zone IDs and its own internal keyswitch assignments. This milestone
reuses that implementation without changing the real-time DSP. The
first source articulation is always Sustain and maps to native default
articulation 0; the alternate becomes a native selectable articulation
with its own key/velocity zones. The exported instrument contains the
recorded PCM and Studio's native mapping, not the source AU.

**Bounded capture:** at most 128 total sample zones; duplicate switch
notes, duplicate names, keyswitch/root-note collisions, invalid MIDI
channels and oversized captures are rejected before AU loading. Existing
single-sound capture remains unchanged.

**Deliberate guardrail:** multi-articulation mode cannot yet combine
with natural note-off release-tail extraction, since the existing
release extractor does not preserve the source articulation label.
Otherwise release recordings could play the wrong articulation. The UI
disables that combination and the core validates it independently.
CC1 layer capture can be used alongside articulation capture if the
total sample budget fits.

**Verification:** new tests cover default compatibility, distinct
source switches, the two-articulation budget, invalid names and
keyswitches, release incompatibility and pre-instantiation validation.
CI must pass macOS builds and tests; actual Garritan/ARIA keyswitch
timing and selected patch persistence need a Mac listening test.
Future iterations should add an editable list of up to 15
articulations, presets for known source banks, and articulation-aware
release extraction.

## Milestone 8 — complete editable articulation list

The Auto Sampler now exposes a dynamic editor for **2–15** source-AU
articulations, replacing the previous fixed Sustain/Staccato pair.
The first row is always **Sustain** (the native default); subsequent
rows have editable technique names and source MIDI keyswitch notes.
Composers can add or remove additional techniques, including Legato,
Pizzicato, Tremolo, Trills, Harmonics and more. The list is passed
directly to the existing M7 capture loop, which records every selected
technique at every selected root and dynamic layer.

The panel shows the exact projected recording count and prevents
captures exceeding Studio's existing **128-zone limit**. Core preflight
also rejects duplicate source keyswitches, duplicate/blank names,
switches colliding with sampled root notes, unsupported channels,
over 15 articulations, and multi-articulation release-tail capture.
All samples are assembled using the existing native Instrument Factory
and its built-in articulation/keyswitch map.

Added tests cover the maximum 15-articulation configuration, an
oversized configuration, and the resulting native zone/articulation
mapping. **Actual AU switching, audible technique correctness and
macOS compilation remain acceptance gates.**

The editor does not infer source library keyswitch assignments and
does not claim automatic recognition of an instrument's articulations.
Future work can add verified per-library presets and editable
native keyswitch destinations.

## Milestone 9 — articulation-aware natural note-off release recordings

The release-tail extractor now preserves each source take's **articulation
name and microphone ID**, alongside its root note and velocity. Native
Instrument Factory groups release-trigger zones by articulation and
velocity, and the existing real-time DSP matches releases to the
articulation held at note-on rather than the articulation currently
selected at note-off. No DSP or live routing changes were necessary.

The M8 articulation editor can now enable natural release-tail capture.
The full plan must still fit **64 held takes plus at most 64 release
zones** (128 total). Core preflight and the UI independently validate
this limit. CC1 crossfade mode remains incompatible with release-tail
capture because the current release dispatcher uses note-on velocity,
not the CC1 crossfade position.

**Related fix:** M4 sustain-loop recommendations now include the
articulation label in their identity and match the correct native zone.
Previously, same-pitch/same-velocity samples from different techniques
could overwrite each other's loop suggestions.

**New regression coverage:** Two source articulations (Sustain and
Pizzicato) with identical root and velocity produce separate release
recordings and distinct native release zones. Tests also verify
multi-articulation capture within the doubled zone budget and reject
oversized plans. No source WAV is modified.

**Acceptance gates:** macOS compile and XCTest, actual ARIA note-off
articulation switching, short and long note-off tails, repeated-note
behavior, cancellation and native package reopen. This feature is
implemented but not yet audio-verified on a Mac.
