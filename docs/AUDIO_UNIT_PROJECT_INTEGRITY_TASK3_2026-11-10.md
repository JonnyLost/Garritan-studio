# Garritan Studio — Task 3: Audio Unit Lifecycle & Project Integrity

Date: 2026-11-10 (EST)  
Branch: `feature/stage-acoustics-sync`  
PR: https://github.com/JonnyLost/Garritan-studio/pull/1

## Source problems verified and corrected

### Project safety

1. **Missing audio could overwrite a good project.** A saved reference with an
   empty `relativePath` caused the `.dawproj` directory itself to be treated
   as an existing audio source. Save now accepts fallback paths only under the
   package's `Audio Files/` directory, rejects traversal components, and
   requires an actual regular source file, not a directory.
2. **Quick Save was not rollback-safe.** Its former code copied some new audio
   directly into the live package before writing the model. Quick Save now uses
   the same complete staged replacement and backup restoration as full Save.
   This trades extra file copying for consistency.
3. **Legacy plug-in records were dropped on full Save.** Existing saved
   `pluginStates` are carried forward when a package is replaced; track/rack
   slot state is also embedded in the project model.
4. Regression tests cover missing-audio rollback for full and quick saves,
   rejecting package directories masquerading as audio, and preserving audio
   previously embedded in the package.

### Audio Unit lifecycle

1. Saving now collects **track insert-effect AU state**, not only track and
   V-Rack instruments. Restoration re-instantiates effects using their
   persisted slot IDs and applies saved state. Failed instantiations are
   unloaded from the host registry.
2. Loading and removing an insert effect keeps ordered project slots,
   attached nodes and host-instance IDs aligned. Graph mutations are made
   while AVAudioEngine is stopped; rollback is attempted if an insertion or
   reconfiguration fails.
3. Rebuilding an insert chain restores the existing **two-way post-panner
   split to dry output and the dedicated Concert Hall send**.
4. Clearing a project now detaches insert Audio Units before clearing the
   plugin-host registry, preventing orphaned effect graph nodes.
5. Reloading a V-Rack instrument uses a new host instance ID; on success it
   updates the persisted slot and unloads the previous host record. Preset
   restoration resolves the new loaded instance instead of a stale ID.
6. Track/rack AU formats and target track nodes are preflighted before
   disconnecting an existing instrument.
7. Track delete snapshots available plug-in state before the undo action.
   Undo/redo reconciles added/removed track mixer nodes; undo-restored tracks
   can rehydrate instrument and insert states.

## CI evidence and limitations

- Earlier GitHub Actions run at commit `cbcff64a` **built every target**,
  including DAWUI and the experimental C capture target. That run's sole
  test failure was the earlier recording writer test, which held an extra
  `AVAudioFile` reference open while reading the WAV. The test now releases
  its final writer reference before readback.
- Final build and test status must be taken from GitHub Actions on the
  **latest branch commit**, not inferred from source readback or earlier runs.
- No physical ARIA / GPO5 Audio Unit or macOS sound device was available to
  validate graph mutation and instrument preset fidelity here.

## Known residual risks to verify before Alpha 1

- Undoing an instrument-slot edit *within* an already attached track is not
  a substitute for an end-to-end MIDI/ARIA audition and may need further
  synchronization; structural track undo/redo was addressed here.
- The experimental Core Audio backend and timing tap still have scheduling
  and actor-ownership concerns identified by the earlier audits; do not
  enable the experimental backend for Alpha 1 testing.
- A plugin can fail during a device restart after the previous instrument
  has been removed. Preflight avoids obvious failure cases, but fully
  transactional AU swaps require hardware validation and more extensive work.
- Quick Save now copies existing audio each time. For large multitrack audio
  projects we should later add a tested incremental save strategy.
- Legacy/corrupt project packages or third-party effects can fail to restore;
  preserve the original files and report exact errors rather than silently
  discarding them.

## Next steps

Task 4: let the macOS CI build and `swift test` complete and resolve
verified diagnostics. After that, one consolidated Mac milestone:

```bash
cd ~/Developer/Garritan-studio
git fetch origin
git switch feature/stage-acoustics-sync
git pull --ff-only origin feature/stage-acoustics-sync
swift build
```

Only after successful compile, check duplicate GPO5 track instruments,
V-Rack replacement and editor identities, added/removed effects with hall
reverb still audible, undo/redo of deleted tracks, and full/quick save/reopen
with MIDI + plugin settings intact.

**Do not merge the feature branch without explicit owner approval.**
