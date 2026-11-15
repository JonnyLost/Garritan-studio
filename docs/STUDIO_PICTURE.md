# Studio Picture — Native Film Scoring

Status: first native scoring implementation on `feature/studio-picture-scoring`.
This branch is based on `integration/studio-alpha1-consolidated-2026-11-14`.
Do not merge until Mac compilation, runtime synchronization and save/relink tests pass.

## The composer workflow

1. Click **Picture** (film icon) in the left sidebar to open the lower workspace.
2. Click **Import Movie** to load a MOV, MP4, M4V or another movie macOS AVFoundation can decode. H.264 and ProRes are useful starting points; actual codec support is determined by macOS and the file's codec, not its extension alone.
3. The picture follows Studio's transport (play, pause, seek and loop). Click or drag on the filmstrip to scrub; the previous/next-frame buttons step a video frame while pausing transport.
4. Choose the movie's SMPTE numbering mode and set its starting timecode. By default the first frame is at `01:00:00:00`. 29.97 and 59.94 include explicit DF/NDF options.
5. Adjust **Picture offset** to place frame zero at a later point in Studio's arrangement.
6. Put the playhead on a key moment and click **Add Hit** (or press **Option-Command-H**). Hit points survive saves, are frame-based and may be clicked to relocate.
7. Mark two hits to see a suggested BPM for 4, 8 or 16 musical beats between them. This is advisory; it does not rewrite your tempo map or MIDI.
8. Click **Float** to detach the same player to a resizable/fullscreen macOS window; click **Dock** to restore the lower viewport. No second video player or transport is created.

Keyboard shortcuts: **Option-Command-P** opens Picture; **Option-Command-H** adds an immediate hit point while a movie is loaded.

## Persistence and media safety

- Only a video **reference** (path plus security-scoped bookmark when available), project offset, frame-rate mode, source timecode, audio/overlay preferences and hit-point data are encoded in the DAW project.
- Movie media is not copied into saved project files. A moved or inaccessible movie must be relinked.
- Relinking preserves project offset, frame-rate numbering and hit points; the user is responsible for choosing the matching picture version.
- Legacy DAW projects decode with `studioPicture == nil`.
- Filmstrip thumbnails are small and generated lazily only when the picture workspace is displayed.

## Timing and limitations

- The audio engine's existing sample-clock position is authoritative. Video presentation uses AVPlayer, with periodic drift correction on the main actor; video decode never runs in the audio callback.
- The displayed SMPTE frame labels are frame-based, including proper drop-frame label skipping. Drop-frame **does not** change playback speed.
- Picture scrubbing maps seconds to beats using the currently active transport tempo, consistent with this Studio branch's existing `seekTo(beat:)` behavior. Complete tempo-map-aware seeking requires work on the transport's musical timebase.
- Guide audio is **muted by default**. Enabling it plays via AVPlayer and does not yet route film audio through Studio's mixer/effects.
- No external LTC/MTC, embedded source-timecode metadata ingestion, streamers/punches, video-with-final-mix export or picture-change conform in this initial milestone.
- Scoring-grade frame-perfect synchronization during heavy playback, especially at device changes, needs a consolidated Mac runtime test with real video files.

## Acceptance test — one consolidated Mac milestone

1. `swift build` and `swift test --filter StudioPictureTimecodeTests` from the feature branch.
2. Import a short H.264 MP4 and ProRes MOV. Confirm images appear in the video pane and filmstrip.
3. While playback runs, use Studio's spacebar, timeline scrub, stop and loop. Confirm picture follows audio and no notes or reverb are lost.
4. Switch 24/25/29.97 DF and verify the expected timecode; try `00:01:00;00` at 29.97 DF and confirm it is rejected.
5. Add hit points, use the menu shortcut, change offset, save and reopen the project. Verify cues and timecode survive.
6. Float and resize the viewer, enter macOS fullscreen, close it, then dock it without losing playback position.
7. Move the referenced movie, reopen the project and use Relink to restore it.
8. Repeat basic playback in a representative large orchestral session to check decode overhead, UI smoothness and sync drift.

## Follow-on milestones

1. **Reference audio routing:** dialogue and production guide audio through Studio mixer with mute/solo.
2. **Robust synchronization:** audio-host-clock scheduling, seek/loop/frame precision, device latency calibration and tempo-map-aware navigation.
3. **Professional film workflow:** cue sheets, streamers and punches, source metadata timecode, picture revisions, optional external MTC/LTC.
4. **Delivery:** export final synchronized movie with Studio mix, configurable start timecode, and independent stem exports.
