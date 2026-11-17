# Studio — Apple's General MIDI sound bank

## Current behavior
At startup the Alpha 1 AVAudioEngine backend creates an `AVAudioUnitSampler` as the default for unassigned MIDI/instrument tracks. Its fallback sound is `gs_instruments.dls` from macOS, with program 0 in melodic bank MSB `0x79` (General MIDI Acoustic Grand Piano). This is an Apple-provided **sample bank**, not Apple's editable oscillator/synth plug-in. The 128 GM **melodic** programs do not imply a drum-kit browser, user synth oscillator editing, or a separate licensed library.

## New user workflow
- Select the startup instrument track and click the **Apple GM · Acoustic Grand Piano** label in its track header. That opens a searchable, categorized Apple bank browser with 128 sounds, program numbers and an **Try C4** button.
- Or open Studio's lower **Instruments** browser, set **Library → Apple GM**, search categories/patches, select a sound, then **Load on Selected Track** or **Add as New Track**.
- The selected program changes the existing Apple sampler in place. No new audio graph, AU editor window, external plug-in, subscription, or sound files are created.
- For a track already hosting Garritan ARIA or a native Studio instrument, the Apple bank loader refuses to replace it and directs the user to **Add as New Track**. This avoids touching ARIA's crash-prone editor and the instrument replacement audio graph.
- The chosen zero-based `appleGeneralMIDIProgram` persists per track; an old project missing the field remains on Acoustic Grand Piano.
- The independent MIDI transmit channel feature from the prerequisite branch applies to Apple sampler too. Program selection is not itself a MIDI transmit channel selector.

## Implementation and boundaries
- Shared `StudioAppleGeneralMIDI` catalog has all 128 melodic GM programs grouped in 16 families and 11 UI categories.
- Fallback track initialization loads the stored program from `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls` (when present).
- UI switching checks program validity and presence of Apple sampler; sends sustain off/all-notes-off on all channels before reloading the sound bank. On failure, it leaves the persisted choice unchanged.
- The existing native **Studio Sampler** remains distinct; no import/export of proprietary DLS, sampling, bank authoring, reverb or MIDI routing changes.
- Full compile/regression and release checks are triggered on macOS GitHub CI; no physical Mac acceptance yet.

## One hardware acceptance milestone
With a disposable project:
1. Launch, select startup piano and open **Apple GM** browser from the track label.
2. Try Acoustic Grand Piano, Music Box, Fingered Electric Bass, Lead 1 (Square), Warm Pad, and an FX sound. Confirm audition notes, levels, patch changes and no hang.
3. Save, close and reopen; selected program must restore before MIDI playback.
4. Create a new instrument track, choose Apple GM in the Instruments sidebar and **Add as New Track**; test keyboard/piano-roll notes on the selected MIDI transmit channel.
5. Verify Garritan tracks, Studio Synth, Sampler, reverb/stage routing and ARIA native editor safety are unaffected.

**Integration:** This is a draft follow-on of the track-MIDI-channel draft, which itself follows the isolated Alpha 1 Mac crash triage draft. None of these changes are in the frozen Alpha 1 test checkout unless explicitly compiled from this feature branch. Do not merge without product-owner authorization.
