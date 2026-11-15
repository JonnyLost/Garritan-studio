# Garritan Studio — consolidated Mac acceptance checklist

**Candidate**: `integration/studio-sampler-portable-packages-2026-11-14`  
**Protected parent**: `integration/studio-safe-consolidation-2026-11-14` (`513804f9097b37eb440a6969d76c2476c9fae9d7`)  
**Scope**: professional MIDI, native Sampler and Synth, stage/Rooms/virtual mics, Ostinato, project save, stems and MIDI export.

This is **one integration acceptance session**, not a demand to repeat every prior development test. GitHub macOS CI validates the Swift debug and release builds, the entire automated Swift test suite and Sampler native DSP sanitizers. Only hardware/audio interaction must be verified on the user's Mac.

## Safe launch — do not touch the working checkout or real music projects

1. Open Terminal on the Mac. Run the following block (stop if any step reports an error):

```bash
cd ~/Developer/Garritan-studio
git fetch origin
git worktree add --detach ~/Developer/Garritan-studio-Acceptance origin/integration/studio-sampler-portable-packages-2026-11-14
cd ~/Developer/Garritan-studio-Acceptance
git rev-parse --short HEAD
swift build
swift test --parallel
swift build -c release --product DAWApp
swift run DAWApp
```

If `~/Developer/Garritan-studio-Acceptance` already exists, stop rather than deleting or overwriting it. A worktree keeps the normal Studio checkout and its current branch intact. Do not run `git reset --hard`, `git clean -fd`, or alter existing projects during these tests.

2. Create a **throwaway project** named `Studio-Acceptance`. Save it to a test folder, never on top of an existing composition. Keep the audio output at a comfortable monitor level.
3. Record **Pass / Fail / Not Tested** per section. For a failure, retain the error message, reproduction sequence and whether audio is silent, distorted or missing.

## One-session interaction matrix

| Area | Short action | Expected evidence |
| --- | --- | --- |
| Track creation | Use the Track menu or TRACKS + button to add **Instrument**, **Sampler**, **Synth**, **Audio** | Each appears as a separate track; no duplicate channels or immediate crash |
| Native Synth | On a Synth track, open its native controls, play notes and alter a parameter | Notes sound; stop causes voices to release; UI remains responsive |
| Native Sampler | Open **Studio Sampler — Mapping**; **Add Samples…** using a short owned WAV; apply mapping; play two different notes | Recorded sample sounds at the mapped pitches; no missing-file alert after apply |
| Instrument Factory | From Sampler Mapping choose **Instrument Factory…**; prepare one sample, label root pitch/velocity and add to mapping | Factory preserves the source file, installs a new managed copy, updates mapping; no data loss |
| Portable instrument | Sampler Mapping **Instruments → Export Portable Instrument…**; then on a second temporary Sampler track **Import .studioinstrument…** | Imported instrument plays; saved package contains its samples; existing instrument remains unchanged |
| MIDI arrangement | Add a MIDI region, draw a chord, copy/duplicate, move, resize, undo/redo and play/loop | Notes remain in the intended positions; no stuck notes at stop, seek or loop |
| MIDI expression | In piano roll draw CC1 and CC11 curves, then use pitch bend; export MIDI and import to another throwaway project | Controller curves and notes remain distinct; velocity, channels and playback timing are retained |
| Articulations | Apply a verified native or instrument-specific articulation map to notes; seek and loop | Articulations trigger before associated notes; no unexpected old-note retriggers; do not assume Instant Orchestra has keyswitches |
| Ostinato | Open lower **Ostinato** workspace, create a short pattern and audition it against a normal instrument track | Pattern aligns to transport and does not break other MIDI tracks |
| Stage and Rooms | Open **Stage** and **Rooms**, move a track, enable reverb and adjust its send; if available add/switch a virtual mic | Track remains audible on dry route; reverb/mic return changes are audible; no silence when returning to dry |
| Mixer | Adjust track fader, pan, mute and solo; switch tracks, then unmute/unsolo | The correct track changes; other tracks retain their own settings |
| Audio export | File → **Export Audio & Stems…**; render stereo, mono and a custom track-selection stem | Each output has valid duration/channels and audible content corresponding to the selected tracks |
| Save integrity | Cmd+S, close/open the throwaway project, verify track types, MIDI edits, instrument mapping, Rooms, Ostinato and mixer settings | Edits persist; previous audio/managed sampler references resolve |
| Unsaved guard | Change a value, invoke File → **New Project** or **Open…** and cancel the prompt; then save and proceed | Cancel keeps the edited project; save doesn't discard new edits made while an older async save finishes |

### Optional compatibility check

If GPO5 and Instant Orchestra are installed and already working on this Mac, load one known preset of each in a throwaway Instrument track and verify playback and MIDI expression. Do not install third-party tools solely for this acceptance test. If no audio interface or recording microphone is available, mark live input recording **Not Tested** rather than blocking the overall software review.

## Stop conditions

**Stop and report immediately** on project data loss, missing audio despite confirmed routing, sustained hung notes that survive Stop, render-thread failures, package import altering original source audio, a crash, or a failed export that silently creates an invalid file. The candidate must not be promoted merely because a subset of tests passed.

## Acceptance record

| Gate | Evidence | Result |
| --- | --- | --- |
| Swift debug + complete regression suite | GitHub Actions candidate-head run | Pending final candidate run |
| Optimized `DAWApp` | GitHub Actions candidate-head run | Pending final candidate run |
| Native Sampler ASan/UBSan and 72-zone stream stress | GitHub Actions candidate-head run | Pending final candidate run |
| Actual Mac audio playback and saving | One-session interaction matrix above | Not yet tested |
| Final promotion decision | Human owner authorization required for shared branch merges | Not authorized |

**Do not merge into `main`, `garritan-integration` or replace a stable checkpoint without the owner's explicit approval.**
