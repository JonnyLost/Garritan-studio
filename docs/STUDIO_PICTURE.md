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

## Scoring workflow milestone 2

- The cue list supports **Edit Cue…**: name, type (cut/impact/action/dialogue/custom), a validated frame-accurate SMPTE position, and director/composer notes.
- Previous/next hit point controls sit beside the frame-step controls. They jump the DAW playhead directly to adjacent video cues.
- **Export Cue Sheet…** writes a portable CSV including ordered cues, cue type, SMPTE frame labels, picture-relative frame numbers, project seconds and notes. Spreadsheet formula-prefix escaping is applied to user-authored fields.
- The video session detects audio playhead jumps and loop wraps and corrects the movie immediately; during ordinary playback it avoids costly seeks until drift meaningfully exceeds a frame budget.
- Changing picture offset or source frame-rate mode resynchronizes the viewer immediately. Replacing media via Relink refreshes the decoder even when the file path is unchanged.
- Releasing a project/viewer now closes the decoder and its security-scoped access. The existing audio and MIDI engines remain untouched.
- New scoring regression tests cover transport jumps, drift, timeline offsets, frame stepping, end-of-movie behavior, overnight SMPTE, CSV safety and older media-reference documents.

**Validation status**: Swift build and tests are run by the Picture macOS CI workflow. Manual video-frame presentation, multiple-monitor floating windows, and live orchestral playback remain a separate Mac acceptance step.

## Milestone 3 — Native picture guide audio and media acceptance

- Movie sound is always muted in AVPlayer. This prevents two unsynchronized copies of dialogue.
- A **dedicated Studio Picture Guide mixer bus** connects to Studio's existing main mixer before the audio engine starts. It bypasses orchestral inserts, stage reverb and track solo/mute; existing audio routing is unchanged.
- Guide audio is **off by default**. When enabled, AVFoundation lazily extracts the movie's audio into an M4A scratch file; playback is file-backed through AVAudioPlayerNode and the Studio mixer, not an uncompressed in-memory copy.
- The Picture lower workspace provides a reference-audio on/off switch, volume, availability and extraction status; Studio's Mixer also contains a named **PICTURE / Guide Audio** channel with its own fader/mute.
- Guide audio schedules from the source file frame corresponding to the film offset, reschedules after a timeline seek or loop wrap, and remains silent before/after the picture.
- Project save persists the reference-audio preference and optional linear gain. Older Picture documents decode with a 65% default when no gain field exists.
- During standard Studio score/stem exports, the guide bus is automatically suppressed, preventing dialogue leakage. Picture audio must never become a track stem accidentally.
- Audio extraction is cancellable; changing pictures or closing the project releases temporary media and bookmark access.
- The new CI tests create a tiny H.264 movie on macOS and verify real video decoding and timecode alignment, alongside source-frame scheduling, offsets, looping, bounds and older project compatibility.

**Runtime acceptance still required on a Mac:** listening to dialogue beside a large orchestrated session, checking long-video seek/loop sync, audio-device changes, and making a final actual file export to confirm guide exclusion. The generated-video CI test validates decoding, not live monitor latency.

## Milestone 4 — Export a scored QuickTime movie

- From **Studio Picture → Export Scored Movie…**, choose a **Stereo Mix WAV** produced by Studio's existing audio export, then choose a destination MOV.
- Studio uses native AVFoundation composition/export to copy the film video and add a newly rendered music track. The original movie and WAV are not modified.
- The saved **picture offset** is respected: if picture frame zero sits at project second 12, export uses the WAV from second 12 onward. The scored MOV starts at movie time zero.
- **Include original dialogue and production audio** is a separate, explicit delivery option (on by default) with an independent level. Turn it off to deliver a music-only scored picture.
- Output duration remains the movie duration; shorter score mixes end in silence rather than stretching the picture. The output is a QuickTime MOV, not yet an H.264 codec-selector interface.
- The exporter works from a previously bounced WAV, not the live audio graph. There is no change to AudioEngine's realtime render path or orchestral session state.
- All rendering is written to a unique staging file, then moved into the destination only on successful completion; source media are never overwritten and existing output names are rejected.
- The UI supports progress and cancellation; incomplete staging files are removed.
- Automated acceptance creates a small H.264 video and Studio-style WAV and verifies a scored MOV contains one video and one audio track, plus duration and output overwrite protections.

**Current boundaries:** This milestone uses the existing Studio stereo mix bounce rather than an all-in-one render. Original embedded movie audio is included only when selected, and burn-in timecode, custom codecs, and frame-level quality assurance are planned separately. Mac playback and end-to-end listening remain required.

## Milestones 6–7 — Frame-budget synchronization and visual scoring cues

- The periodic AVPlayer drift tolerance is now tied to the actual picture frame rate (approximately two video frames, rather than a fixed 100 ms). To protect MacBook efficiency, automatic video-seek correction remains throttled at 650 ms; deliberate transport jumps and loop wraps still seek immediately.
- Native **streamers** now sweep across the film to an upcoming hit point. A **single-frame punch** flashes at the marked hit; they are visual scoring aids and do not alter video files or rendered music.
- Hit-point cue math is based on movie frames and the saved picture offset, never beats or wall-clock guesses. The earliest upcoming hit wins and works with 23.976/29.97/59.94 numbering modes.
- Composers can toggle streamers and punches independently and select 1, 2, 3 or 5 seconds of visual lead time. Settings persist with the Studio project and older files continue decoding correctly.
- The overlays use SwiftUI drawing above the existing one-player surface in docked or floating mode. No additional video decoder, timer, plugins or realtime audio callbacks are added.
- Regression tests cover the exact punch frame, picture offsets, 29.97 drop-frame, cue selection, legacy save migration, invalid lead settings and frame-rate-adjusted drift tolerances.

**Still required:** audio-device latency calibration, fully tempo-map-aware locator/navigation, host-clock/video presentation verification, and a consolidated MacBook video listening/viewing check. The visual punch is selected from the current published transport frame; actual display latency must be measured on the Mac, not assumed from passing unit tests.

## Milestone 8 — SMPTE locator and professional cue navigation

- **Go to SMPTE** accepts an absolute timecode label and seeks to the exact picture-relative frame after validating the frame rate, drop-frame numbering, project offset and movie duration.
- **Cue search** filters hit-point names, notes and timecode; **Cue type** filters action/cut/dialogue/impact/custom. Previous/next cue navigation follows the visible filtered set.
- Reference movies are inspected for dedicated embedded SMPTE timecode tracks. Presence is shown without fabricating the starting label. Manual **Start TC** remains authoritative: reading and validating timecode *samples* is a separate future capability, as is MTC/LTC synchronization.
- Cue search/filter is display-only and does not rewrite project hit points, tempo, or audio routing.
- Tests cover cue selection, empty matches, filtered traversal, SMPTE jumps, out-of-range labels and 29.97 DF invalid labels.

## Milestone 9 — Movie delivery options and permanent timecode labels

- **Export Scored Movie** now offers high-quality QuickTime MOV, high-quality MP4 and an HEVC QuickTime MOV preset. Codec availability is checked against AVFoundation at export time; a format unsupported by the installed macOS environment produces an error instead of a mislabeled movie.
- **Burn SMPTE timecode** renders picture-relative start timecode plus movie frames directly into the delivered video. Burn-in is optional, offline-only, and independent of Studio's live video player and audio rendering.
- The permanent timecode label respects the project's manually configured Start TC, exact fractional frame rate, DF/NDF numbering and 24-hour wrap. Burn-in refers to movie time zero, not the music's later picture offset.
- The exported music remains an already-bounced Studio Stereo Mix WAV; source media, mixing state and the project document remain untouched. Original picture dialogue remains an independent optional delivery setting.
- The staging filename matches the selected container extension. Every successful export requires a supported output type; existing destinations are never overwritten.
- New acceptance tests cover SMPTE label arithmetic and H.264/MP4 export with overlay processing using native AVFoundation.

**Remaining delivery work:** integrated one-step music bounce + movie delivery, configurable audio codec/bit depth, long-video performance checks, source-color preservation, external delivery standards, and MacBook visual/listening acceptance.

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
