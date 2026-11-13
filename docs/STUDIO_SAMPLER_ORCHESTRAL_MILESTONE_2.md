# Studio Sampler — Professional Orchestral Sampling (Milestone 2)

Branch: feature/studio-sampler-native. Existing integration branch remains untouched. Milestone 1 portable packages and project JSON continue to use version 1 with optional backward-compatible fields.

## New playable orchestral techniques

**Recorded interval legato:** enable Overlap Legato in the sampler performance page. Hold the source note and play a destination pitch on the same MIDI channel. If an imported recording explicitly matches that exact from→to interval, the native sampler plays it as a one-shot over the destination sustain and crossfades the previous note out. If no interval recording matches, Studio simply crossfades the two sustained notes; it does not invent a true recorded transition or claim to model an absent slur. All other tracks, channels, articulations, and non-overlapping notes retain their usual polyphonic behavior. Default off for legacy patches.

Recorded interval files can be named like Violin_fromC4_toD4_legato_close.wav and Violin_fromC4_toD4_legato_room.wav. Studio recognizes and maps the exact from-note and destination root. A recording used as a transition must not have a sustain loop or release-trigger flag. The editor also permits manually enabling a zone as a recorded transition and setting its from pitch. Tune the outgoing/incoming crossfade between 5 and 250 milliseconds in the performance page. Transition recordings should contain their actual legato noise/connection, not a repitched full sustain sample.

**Multiple microphones:** capture and import the same note/articulation at up to four positions (Close, Main / Tree, Room, Spot), named with tokens such as _close, _tree, _room, or _spot. Position identity is saved per zone and avoids inadvertently treating microphones as velocity layers. Each available microphone position plays its matching recording in parallel; a dedicated performance mixer can adjust its smoothed gain (0–2), pan (-1 to 1), and mute state. The mixer does not generate missing recordings; use coherent, phase-aligned source recordings when mixing multiple positions. Release-trigger recordings also play for each available microphone. Unnamed recordings remain on default microphone 0.

**Expression:** CC1 controls continuous dynamics or layer morphing; CC11 controls expression; new CC2 adjusts breath intensity and CC21 introduces smoothed 5Hz pitch vibrato (up to approximately ±0.35 semitones). Both controls are available from live MIDI and the sampler's own performance interface, with default CC2 full intensity and CC21 no vibrato so older patches sound unchanged. Performance values, microphone mixer settings, and legato mode persist with projects and portable .studioinstrument packages.

## Performance and safety

- All sample decoding, disk streaming, and mapping edits remain outside the audio render callback.
- The C++17 engine adds only fixed-size voice metadata, channel controller arrays and four microphone controls; no commercial plugins or new SDKs.
- Mic and vibrato calculations are shared per render frame rather than repeated per voice.
- Recorded transitions and sustained samples use existing streaming and voice-stealing infrastructure.
- Crossfades are bounded and smoothed; old note-off events after a legato handoff cannot trigger a second release tail.
- Max 128 zones and 64 DSP voices (Swift default 32). A four-microphone, multi-dynamic-layer instrument consumes more polyphony, so design mappings with hardware limits in mind.

## Automatic mapping and editing

- Key/velocity groups are now inferred separately by articulation, microphone, and transition source note.
- Manually adjusted mic and legato metadata is preserved when the mapping is automatically rebuilt; new imports merge microphone definitions into the instrument.
- Review generated mappings in Edit Mapping. An exact from→to transition should target one destination note and share the articulation and microphone of its sustaining sample.
- The Instrument Summary and performance page show the number of available recorded transitions and microphone controls.

## Regression and integration

Standalone native DSP tests cover simultaneous mic playback, gain/pan, breath, and overlap-triggered interval recordings. Swift tests cover filename recognition, patch persistence and invalid mappings. The studio-sampler GitHub Action builds and tests on macOS and performs sanitizer/stress testing on Linux. A final real Mac playback milestone is still required to judge sonic realism and latency before integration/merge.

These features complete the first professional orchestral sampler *engine workflow*. High-quality orchestral results still depend on the recording material supplied by the composer. Automated capture, phase calibration, richer transition direction/speed detection, and a full factory sample library belong to later development.
