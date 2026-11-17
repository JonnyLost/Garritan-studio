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
