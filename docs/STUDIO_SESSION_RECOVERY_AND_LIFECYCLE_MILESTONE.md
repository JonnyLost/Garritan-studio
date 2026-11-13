# Studio — Unsaved Session Recovery and Lifecycle Handoff

**Branch:** `architecture/studio-independence`  
**Based on:** `integration/studio-complete-mac-test`  
**Purpose:** protect unfinished music and prevent accidental data loss during
window Close, application Quit, and interrupted sessions. This milestone does
not change audio DSP, instrument hosting, MIDI scheduling, or the existing
serialized `.dawproj` format.

## Implemented architecture

### 1. Native local crash-recovery packages

`DAWCore/Sources/DAWCore/Persistence/StudioDraftRecoveryStore.swift`

- Maintains a private location:
  `~/Library/Application Support/Studio/Recovery/`.
- Writes a unique `<session UUID>.dawproj` package using the same
  transactional `ProjectFileManager` as normal Save. It includes the
  project's audio references, embedded audio files and AU/plug-in state.
- Does not replace a manually saved project, does not modify Open Recent,
  and does not use the inherited MusioCreate storage path.
- Skips corrupt drafts without deleting them; existing complete backups
  remain intact on a failed write.
- Lists recovery candidates with their metadata, loads by validated
  recovery UUID/path, and deletes only the requested draft on explicit
  discard or successful clean Save.
- Supports actor-injected temporary directories for regression tests.

`DAWApp/Sources/DAWApp/StudioDocumentSession.swift`

- Schedules an untitled recovery snapshot five seconds after the last edit;
  also requests a snapshot on window/app deactivation.
- Coalesces rapid edits and verifies the session ID before/after each write.
- On launch offers the most recent intact recovery copy:
  **Restore / Later / Discard Copy**.
- Restoring opens the project as a new **unsaved** session, not a silent
  replacement of the original recovery file. Save As chooses a permanent
  `.dawproj` location, copies embedded audio, then removes that draft.
- A user-visible error warns if a recovery snapshot cannot be written
  (for example, if a required external audio file has disappeared).
- A cancelled Save, failed Save, or invalid imported document leaves the
  current project intact and its recovery data undiscarded.

**Important:** crash recovery is *best effort*, not a zero-data-loss
journal. A crash within the five-second debounce window can lose the most
recent edits. A damaged or missing audio source can prevent a new complete
recovery snapshot. Preserve valuable work with regular Save.

### 2. Safe window Close and application Quit

`DAWApp/Sources/DAWApp/StudioApplicationLifecycle.swift` negotiates
`applicationShouldTerminate` using AppKit's asynchronous termination reply.
Edited projects must pass **Save / Cancel / Don't Save** before the
application can quit. Cancel or failed Save refuses termination.

`DAWApp/Sources/DAWApp/StudioWindowCloseGuard.swift` installs an
`NSWindowDelegate` forwarding proxy to intercept ordinary Close while
preserving unrelated SwiftUI window-delegate events. The guard is mounted
outside the project-specific view identity to survive reloads.

The app now presents one `Window` rather than a `WindowGroup`, matching
the current single-document `AppState`. This avoids multiple composing
windows incorrectly sharing one mutable project controller. This is not yet
an `NSDocument` multi-window DAW.

The same Save/Cancel/Don't Save policy applies to both Close and Quit,
but AppKit may bypass `windowShouldClose` during application termination;
hence the **separate** application delegate.

### 3. Typed project save snapshot

`DAWUI/Sources/DAWUI/Services/StudioProjectSnapshotBridge.swift`

- Replaces the unscoped `requestProjectForSave` /
  `projectDataForSave` request-response pair with a typed closure bound
  to the active project UUID.
- Stale windows cannot return a project for a newer session or unregister
  its snapshot provider.
- `MainWindowView` registers on appear and unregisters on disappear.
- AU state and interface-layout preparation still uses the existing
  `savePluginStates` notification for compatibility; converting the
  remaining plugin commands into typed interfaces is a subsequent stage.
- Snapshot capture suppresses accidental dirty-revision increments caused
  solely by reading plug-in state. Actual user edits remain revision-tracked.

## Automated regression coverage

- `StudioDraftRecoveryStoreTests`: save/load/discard, separate sessions,
  corrupt recovery preservation, audio inside recovered packages.
- `StudioProjectSnapshotBridgeTests`: session-scoped reads, stale-window
  unregister, mismatched project protection.
- Previously established `StudioSessionRevisionTests`,
  `StudioAutosaveManagerTests`, `StudioProjectFormatCompatibilityTests`,
  audio path/rollback/recovery suites and original DSP/DAWCore tests.
- Existing macOS GitHub Actions jobs check normal local-first and opt-in
  cloud-compatible app builds and Release mode. Verify the **latest commit**
  before treating these as passing results.

## Mac acceptance testing (future consolidated milestone)

Manual graphical acceptance is still necessary for:

- Close and Quit with Save, Cancel and Don't Save;
- Save As dialog cancellation without losing the open session;
- restore-after-forced-termination with an unsaved MIDI project;
- recovery of an audio recording with its original file removed;
- installed ARIA and Audio Unit states after recovery;
- relaunch with multiple recovery drafts, SwiftUI window lifecycle, and
  close/reopen behavior.

These are **not** claimed to be hardware/runtime-tested by CI.

## Known limitations

The UI currently offers the newest draft at startup. Choosing **Later**
preserves it for a future launch; a full in-app multi-draft browser remains
a future improvement. The background snapshot is a five-second debounce, not
continuous journaling. The close delegate is verified by macOS compilation
but awaits hands-on window-close validation. No branch merges or project
schema migrations have been performed.

The application remains in a staged independence transition; its audio/MIDI
internals and inherited artwork/provenance require separate review.
