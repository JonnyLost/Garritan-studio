# Studio Sampler — Instrument Factory (Milestone 3)

**Feature branch:** feature/studio-sampler-native. Do not merge without explicit approval.

## In-application creation workflow

1. Open a MIDI/instrument track and choose **Open Studio Sampler**.
2. In the **Mapping** workspace, select **Instrument Factory…**. Empty sampler instruments also show **Record / Build Instrument…**.
3. Label the upcoming recording before capture: root MIDI note, played velocity, microphone position (Close/Main/Room/Spot), articulation, and whether it is a release or an exact recorded legato interval. Recording an interval requires a distinct *From* pitch and a *to/root* pitch.
4. Press **Record Sample**. Studio asks for the microphone permission macOS requires and uses the existing AudioRecorder / BufferedAudioCapture audio-input pipeline. **Stop & Prepare** finalizes the file after the input tap is removed. No second tap/record engine is created. Studio's normal transport recording is mutually excluded.
5. Alternatively choose **Import Audio…** to prepare one or more existing WAV/AIFF or other AVFoundation-supported mono/stereo audio files.
6. Preparation reads input in 8,192-frame blocks on a background worker. Optional silence trim, up to 5ms attack padding, configurable gate threshold, -1dB peak normalization (max 8x gain), and fade-in/out are applied into a **new** 32-bit float WAV. Stereo channels are processed together with shared gain and trim endpoints. Original input audio remains unchanged.
7. Continue capturing takes. Each added take retains its explicit labels, independent of filename. Remove unwanted takes in the list. Press **Add Takes to Instrument** to import private, app-owned copies and assemble an editable patch. The original temporary capture/processed files are cleaned after a successful or failed import.
8. Review the key/velocity/articulation/microphone map. Press **Apply Mapping** to make the instrument playable, then **Instruments → Save to Studio Library…** or **Export Portable Instrument…** to preserve a self-contained .studioinstrument.
9. Edit the original sample start/end, loop points, crossfades and fade ramps in the existing non-destructive **Waveform & Loops** editor. **Find Loop** remains available. Instrument Factory does not overwrite a real source recording.

## Recording and safety

- Capture uses the same real-time-safe buffered recording worker already used by Studio for audio tracks, with microphone permission and input metering.
- The factory refuses to start if the main DAW transport or audio recorder is already recording.
- Closing the factory during capture/preparation is disabled; dismissing an idle factory discards only temporary prepared files owned by the session.
- Invalid note/velocity/articulation or over-limit batches are rejected before copying any sample files.
- If a handoff fails, Studio backs up the processed WAV takes to Application Support/GarritanStudio/SamplerFactoryRecoveries and shows that recovery location. The originals are not destroyed. Successful imports remove only temporary prepared copies.
- A capture batch maps the same root note at multiple velocity levels into disjoint velocity bands; roots map to nearest-key ranges separately by articulation, mic and interval source. New articulations merge through existing stable keyswitch logic rather than changing previously edited patches.
- All sample audio processing is outside ss_render and all capture disk writes are outside the input tap. No file decoding, heap allocations or file writes are added to the audio render callback.
- Max 128 recorded zones, 15 additional articulations, four microphone positions and the existing bounded sampler voice budget remain unchanged.

## Original factory starter instruments

The **Install 4 Original Studio Sounds** action builds a small native starter library without third-party assets. It generates deterministic PCM using Studio's original harmonic synthesizer routine, makes four keyed recordings per instrument, assigns a usable patch, and packages the audio together with its mapping:

- **Studio String Sketch** — layered synthetic harmonics, designed as a *sketch/texture*, not an acoustic string recording
- **Studio Air Pad** — softly evolving synthesized ensemble pad
- **Studio Glass Keys** — decaying inharmonic partials
- **Studio Plucked Tone** — decaying picked harmonics

The installer is idempotent: it will not duplicate a correctly labeled Studio Original already in the instrument catalog. A failed batch removes only the newly created packages, never previously installed instruments. All source waveforms are generated on demand in a temporary directory and included inside portable .studioinstrument packages. Nothing from commercial sample libraries or plugins is redistributed.

The original starter instruments are **proof-of-workflow/sound-design templates**, not a complete, multi-dynamic orchestral library. Building richly expressive violin, wind, choir and percussion sample sets still requires original capture sessions or user-supplied recordings.

## Tests and downstream work

- StudioSamplerInstrumentFactoryTests: original audio preserved on offline edit; trim/normalize accuracy; invalid/silent files; explicit velocity and microphone bands; instrument merging; invalid legato preflight; original factory package idempotence and integrity.
- Existing Studio Sampler core DSP sanitizer/stress and DAWCore macOS CI remain active.
- Real Mac microphone recording, equipment setup, latency, capture noise floor, physical articulation accuracy, mic phase alignment and subjective instrument quality remain for the consolidated Mac test milestone.
- Future enhancements may include automatic pitch estimation, microphone alignment measurement, multisample capture sequencing via MIDI note prompts, loop-click audio analysis and substantial original orchestral recording sessions. Those are not claimed as finished here.
