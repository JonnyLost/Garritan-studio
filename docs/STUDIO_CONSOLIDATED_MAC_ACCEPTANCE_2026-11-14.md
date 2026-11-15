# Garritan Studio — consolidated Mac acceptance checklist

**Validated snapshot:** `checkpoint/studio-alpha1-ci-green-2026-11-14` — commit `47f6d887be3a5f781d33fb83e98472f2c343e3a1`.  
**GitHub validation:** [Final unified Alpha 1 CI passed](https://github.com/JonnyLost/Garritan-studio/actions/runs/43663886947) — macOS full debug build, complete Swift tests, release DAWApp, native Sampler sanitizers and 72-zone stress.  
**Scope:** MIDI, Sampler, Synth, Granular, Ostinato, Rooms and virtual mics, audio/stems export, and project save/reopen.

This is one hands-on Mac acceptance session, not a request to repeat all completed automated tests. It is **not** a claim that runtime audio, physical MIDI devices, ARIA, or window/document workflow have passed.

## Safe launch — tested code frozen, existing projects untouched

Use a Mac with Xcode/Swift and the existing Studio checkout at `~/Developer/Garritan-studio`. Open Terminal and paste this **single block**:

```bash
cd ~/Developer/Garritan-studio
git fetch origin
git show origin/integration/studio-alpha1-consolidated-2026-11-14:Tools/alpha1_mac_launch.sh > /tmp/studio-alpha1-launch.sh
bash /tmp/studio-alpha1-launch.sh
```

The launcher validates the immutable green checkpoint, then creates `~/Developer/Garritan-studio-Alpha1` as an isolated detached worktree and builds/runs its `DAWApp`. The normal Studio checkout is **not** switched, cleaned or reset. It will stop rather than overwrite any existing unrelated folder. Build and runtime output is saved locally in `~/Library/Logs/GarritanStudio/Alpha1/` for investigating failures. The script is downloaded from our own GitHub branch; review it in the repository first if desired.

Create a brand-new throwaway project called `Studio-Acceptance` in a test folder. **Do not open or save over your important projects.** Keep speakers at a conservative volume. For each feature below record **Pass**, **Fail** or **Not Tested**. A failure is useful evidence, not a reason to delete the worktree or reset a branch.

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
| Swift debug + complete regression suite | GitHub Actions candidate-head run | Passed on immutable checkpoint 47f6d887 (GitHub run 43663886947) |
| Optimized `DAWApp` | GitHub Actions candidate-head run | Passed on immutable checkpoint 47f6d887 (GitHub run 43663886947) |
| Native Sampler ASan/UBSan and 72-zone stream stress | GitHub Actions candidate-head run | Passed on immutable checkpoint 47f6d887 (GitHub run 43663886947) |
| Actual Mac audio playback and saving | One-session interaction matrix above | Not yet tested |
| Final promotion decision | Human owner authorization required for shared branch merges | Not authorized |

**Do not merge into `main`, `garritan-integration` or replace a stable checkpoint without the owner's explicit approval.**
