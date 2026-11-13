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

## Follow-on: coordinated manual Save / autosave writes

A manual Save now calls `AutosaveManager.beginManualSave()` **after**
the user chooses a destination and **before** capturing a project snapshot.
The manager prevents new autosave writes and waits for any in-flight autosave
to finish. A `defer` releases the hold on success, failure or cancellation.
The existing dirty markers and session-revision checks continue to determine
whether the completed snapshot is current. This closes a potential
last-writer-wins race where an older autosave could overwrite a newer manual
Save on disk. Added deterministic XCTest coverage for an autosave blocked by a
manual Save and a manual Save waiting for an in-flight snapshot.

## Exit guard while file operations are in progress

Application Quit and window Close now consult
`AppState.needsExitNegotiation`, which includes both unsaved revisions
**and** in-flight Save or project transitions. An active operation cannot
be abandoned simply because the Edited marker is momentarily clear;
`confirmApplicationTermination()` refuses to close while these operations
are running. A later, explicit Close/Quit can succeed when the operation
finishes. This avoids a premature exit while a project package is being
written or switched.

## Native plugin-state preparation milestone — November 13, 2026

`StudioProjectSnapshotBridge` now supports an optional project-scoped
`prepareForSave` callback as well as the already scoped snapshot, cleanup,
and restore callbacks. `MainWindowView` registers the callback on appear.
It synchronizes the current DAW layout, obtains Audio Unit/instrument state,
and returns the active `Project` to `AppState` before a save ticket is
captured. The document controller no longer posts the global
`savePluginStates` notification.

This replaces the last application-level save/clear/restore broadcast in the
document workflow. Obsolete notification-name declarations were removed from
`KeyboardShortcuts.swift`; the notification-based project edit event and
engine-ready event still exist and are separate possible future migrations.

Regression tests cover stale project IDs not triggering side effects, a
valid active project preparing once per save, old windows failing to
unregister the current view, plugin lifecycle isolation, and rejecting a
snapshot with the wrong project ID.

Instrument state is still collected using the existing
`ProjectViewModel.saveAllPluginStates()` implementation. This is a
communication/ownership refactor, **not a rewrite of audio or AU hosting**.
Graphical UI transitions, the sound of restored instruments, and actual
macOS close/quit interaction remain consolidated Mac acceptance tests.

CI must run on the new commit before this milestone is described as
automatically verified. No integration branches have been merged.
