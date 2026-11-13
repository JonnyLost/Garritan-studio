# Studio Sampler — Empty Instrument Workflow

Feature branch: `feature/studio-sampler-native`.

## User workflow

1. Select an existing MIDI or instrument track.
2. Click its instrument slot to open the instrument browser.
3. Choose **Open Studio Sampler**. This action now opens the sampler interface
   immediately; it does **not** open a file picker.
4. An empty Studio Sampler opens in the mapping workspace, where the
   **Add Samples…** button is immediately available. You can instead select
   **Explore Controls** to examine the different native sampler performance
   layouts before importing anything.
5. Click **Add Samples…**, choose WAV, AIFF or another supported audio
   recording, review the automatic key/velocity assignments, then choose
   **Apply Mapping** to install the playable sampler.
6. The performance interface now displays the mapped instrument. Return to
   **Edit Mapping** for sample zones, looping, fades and other controls.

Clicking the assigned **Studio Sampler** instrument slot afterward opens the
sampler interface directly. It is also available in the lower **Instruments**
workspace, and from the track's **Open Studio Sampler Instrument…** menu.

The original one-step **Quick Import Samples…** command remains available in
the browser for users who specifically want to import recordings immediately.

## Behavior and persistence

- Empty samplers are saved with a version-1 `StudioSamplerPatch(zones: [])`.
- An intentionally empty patch is **not** a playable sampler mapping
  (`isValid == false`), so the engine does not attach an audio node or
  incorrectly play a default/fallback sample.
- The MIDI track retains its empty sampler selection across track and
  project JSON saves. Its controls may be explored without generating audio.
- Switching to an empty sampler releases any previous instrument instance
  using the existing audio/plug-in cleanup path; reopening an already
  populated sampler preserves its sample mappings and live voices.
- Once samples are imported and **Apply Mapping** succeeds, the existing
  native `StudioSamplerInstrument` is loaded as before. No changes to
  streaming, MIDI routing, ARIA, or the synthesis engines were required.
- The old import button was renamed to distinguish **opening an instrument**
  from **choosing files**.

## Verification

Unit coverage: `testEmptySamplerSelectionPersistsWithoutPretendingItCanPlay`
in `Tests/DAWCoreTests/StudioSamplerTrackIntegrationTests.swift`.

The dedicated sampler CI workflow compiles SwiftUI and the DAW, runs
the native DSP sanitizer suite and Swift regressions, then compiles
`DAWApp` for release. This change is not merged into the user's separate
integration/Mac-testing branch until explicitly authorized.
