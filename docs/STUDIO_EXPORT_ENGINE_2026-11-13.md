# Studio Export Engine — Native Mixdown, Track and Custom-Stem Milestone

**Date:** November 13, 2026  
**Repository:** \`JonnyLost/Garritan-studio\`  
**Base:** \`feature/studio-track-workflow\` at \`c5a6d997bfedba504c5a6d2f4862173c005aed6a\`  
**Current feature branch:** \`feature/studio-export-engine\`  
**Integration:** Draft stacked change; neither parent nor export branch may be merged without owner approval.

## Composer-facing workflow

File → **Export Audio & Stems…** opens the native macOS Export Studio dialog:

- **Stereo Mix:** a single stereo master render honoring the current full-mix mute/solo state.
- **Mono Mix:** an actual one-channel WAV downmix, not a stereo file with an inaccurate filename.
- **Individual Tracks:** choose any subset of project tracks, each exported to a separate stereo WAV.
- **Custom Stems:** create, name, combine and delete groups; add entire automatic families (Strings, Brass, Woodwinds, Percussion, Keys, Choir, Synth, Sampler, Audio or Other), then add/remove arbitrary individual instruments. A channel may intentionally appear in several stems.
- **PCM output:** 16- or 24-bit WAV at the Mac's current audio-device sample rate.
- **Reverb/Release tail:** composer-selectable 0–15 seconds.
- **Destination:** a user-selected output folder, individual progress and Cancel.

Factory Synth, native Sampler, audio tracks and Garritan instruments are rendered through the existing signal graph; a pass's track selection is a *copy* of project content, not a rewiring of instrument data or destructive project mute changes.

## Confirmed source findings and fixes

1. The master mixer already used an installTap callback to drive MIDI timing. A second independent master tap risks replacing MIDI scheduling. Export uses a **combined** main mixer tap that preserves the original MIDI callback and forwards PCM into the existing \`BufferedAudioCapture\` lock-free ring. Disk writing always runs on its writer queue, not the audio thread.
2. Recorded audio clips were previously connected directly to \`engine.mainMixerNode\`, bypassing their track channel inserts, pan, mute/solo and stage Hall send, and double-applying \`track.volume\` in certain paths. Their normal playback route is now **file player → track.inputMixer → channel processing → independent dry and hall send**. The player applies clip gain only and the channel owns the track fader.
3. Stems mute all non-selected track nodes at *both* dry and hall send points, filter MIDI/audio playback preparation to the selected track IDs, stop live MIDI playthrough, mute the independent V-Rack sum output, reset held voices and per-channel inserts, and reset the shared hall reverb between passes.
4. Every output pass is captured in real time using the existing AVAudioEngine and Audio Unit graph. The UI remains responsive via short asynchronous sleeps while the audio callback records independently. Source files are not loaded into a monolithic RAM buffer.
5. Export staging occurs in a hidden same-volume folder. A session is committed only after all passes finish, sample frames are checked for capture underruns/disk errors, final WAV headers are generated and each file has the identical frame length. Existing files are **never overwritten**; a failed final move rolls back only files created by the present export. A canceled or interrupted export cleans the staging directory and restores normal timing and mixing.

## Implementation files

- \`DAWCore/Sources/DAWCore/Export/StudioExportPlan.swift\`: pure pass planner, family categorization, safe filenames, tempo/loop restrictions and project isolation.
- \`DAWCore/Sources/DAWCore/Audio/AudioEngine.swift\`: shared timing/export tap, stereo capture, hall/effect reset and dry/hall isolation.
- \`DAWCore/Sources/DAWCore/Audio/PlaybackEngine.swift\`: channel routing fix, rack bypass protection and instrument-state reset.
- \`DAWUI/Sources/DAWUI/ViewModels/ProjectViewModel.swift\`: export override for playback and protection from live MIDI input.
- \`DAWUI/Sources/DAWUI/Views/StudioExportCoordinator.swift\`: controlled, sequential real-time bounces, PCM conversion and transactional output.
- \`DAWUI/Sources/DAWUI/Views/StudioExportView.swift\`: UI for all four export modes and stem membership.
- \`DAWUI/Sources/DAWUI/Views/MainWindowView.swift\`, \`Shared/KeyboardShortcuts.swift\`, \`DAWApp/Sources/DAWApp/DAWApp.swift\`: File menu and sheet hookup.
- \`Tests/DAWCoreTests/StudioExportPlanTests.swift\`: family, membership, sanitization, mixed output, solo/mute, timing and invalid selection tests.
- \`Tests/DAWUIWorkflowTests/StudioExportPCMWriterTests.swift\`: actual 16-/24-bit WAV conversion, channel counts, mono downmix and zero-padded tails.

## Explicit support boundaries

This is a **real-time bounce milestone**, not the eventual faster-than-real-time offline renderer. On-screen playback and actual AU/DSP processing happen during the pass; each output requires the duration of the project plus tail seconds. Sound devices must be available; the experimental Core Audio backend is rejected. No hands-on Mac test has been started.

- The currently separate **V-Rack multitimbral routing** is not included when rendering individual track/stem selections. Any selected MIDI track routed directly to a shared rack fails clearly rather than silently omitting or leaking audio. The rack bus is muted for currently supported passes. Dedicated V-Rack render buses are a follow-up.
- Projects with **tempo changes or looped clips** are rejected by this initial renderer because the current playback clock does not yet preserve those semantics consistently. This is preferable to exporting misaligned music.
- **WAV RIFF size bounds** are checked; RF64 and 32-bit floating-point export are future extensions.
- A real-time pass is guaranteed to have the same *file frame count*, but independent real-time starts are not yet guaranteed sample-identical alignment across bounces. Future render-clock synchronization will address this.
- Effects with unusual plug-in reset behavior, master-bus nonlinear processing, send automation, live instrument notes and ARIA-specific timing still need actual consolidated Mac acceptance; automated tests do not establish these properties.
- Audio clip scheduling/warping uses existing playback behavior. Project audio regions with uncommon sample rates/warp modes should be checked during the consolidated Mac milestone.

## Verification gates

The stacked base \`feature/studio-track-workflow\` was independently verified for macOS debug compilation, the Swift test suite and native DSP checks. Export branch CI must run:
1. Swift parse plus standalone Synth, Granular, Sampler and shared-PCM sanitizer programs.
2. Complete Studio macOS debug build.
3. DAWCore, DAWUI workflow, audio and MIDI regression tests including export planner and PCM WAV writer.
4. Optimized DAWApp release build.

Release build, hardware playback and MIDI/ARIA audition must never be reported as passed until checked. The user explicitly deferred consolidated Mac testing.

## Next dependencies

- Render graph isolation for V-Rack channels/aux sends.
- Immutable audio-plugin state cloning and reliable faster-than-real-time rendering.
- Unified tempo map and MIDI sample clock.
- Time-range/loop/cycle selection, RF64 and optional 32-bit float WAV, broadcast WAV metadata.
- Export presets, loudness metering, dither, normalization and professional delivery naming.
