# Studio native project/session milestone

Branch: `architecture/studio-independence` — based on `integration/studio-complete-mac-test`.
No branches were merged.

## Objective

Replace the inherited monolithic application document controller with a
Studio-owned session lifecycle while preserving the working audio/MIDI engine,
existing `.dawproj` files, Audio Unit state, and historical JSON imports.

## New session boundaries

- `DAWApp/Sources/DAWApp/StudioDocumentSession.swift`: Studio's main-actor
  session controller for New, Open, Save, Save As, user confirmation, dirty
  markers, error alerts, and instrument restoration.
- `DAWCore/Persistence/StudioSessionRevision.swift`: immutable session ID
  and revision receipts; older saves cannot mark newer edits clean.
- `DAWCore/Persistence/StudioAutosaveManager.swift`: single file manager
  actor shared with manual saves, with generation and revision checks.
  It captures instrument state via the same UI snapshot callback as manual Save.
- `DAWCore/Persistence/StudioProjectPackagePaths.swift`: validates relative
  media paths and blocks package traversal or symlink escape.
- `DAWCore/Persistence/StudioInterruptedSaveRecovery.swift`: restores a
  complete backup when a crash interrupts replacement of a `.dawproj`,
  without promoting partial staging or overwriting existing work.

## User-facing behavior

1. Creating/opening a new project asks **Save / Cancel / Don't Save** when
   the active project contains unsaved edits. A cancelled or failed Save keeps
   the active session.
2. Open fully decodes the next document before clearing the old audio graph.
   Invalid or newer project versions are reported rather than silently
   converted.
3. Save As uses the same normalized `.dawproj` destination that the
   persistence actor actually writes.
4. Older bare-JSON projects can open but are treated as imported, edited
   sessions. Saving them offers a new `.dawproj` destination and never
   autosaves over the original JSON file.
5. A new view publishes an engine-ready event with its project UUID before
   instrument restoration; no arbitrary half-second delay is required.
6. The window title displays the active project and its edited state; file
   operation errors appear in a macOS alert.
7. Opening missing packages searches for a complete interrupted-save backup
   in the same folder and preserves incomplete staging for diagnosis.
8. Repeated Save protects audio already inside the project if its original
   external source has since disappeared.

## Compatibility invariants

- Serialized schema: `version`, `project`, `audioFileManifest`,
  `pluginStates`
- Package structure: `project.json`, `Audio Files`, `Plugin States`
- File extension and UTType: `.dawproj`, `com.musio.create.project`
- Historical bundle and recording identifiers remain unchanged until a
  separate migration is approved and tested.
- Existing working sound-engine, synth, sampler, stage and MIDI code is
  **not** rewritten by this milestone.

## Regression coverage

New XCTest suites cover session revision and stale receipts, autosave race and
session cancellation, legacy metadata and future-format refusal, relative-path
and symlink safety, interrupted backup restoration, and repeated saves when
external recordings disappear. Existing DAWCore and DSP tests remain in CI.

## Known limitations and next gates

- This is still an app-wide single-session controller, not an NSDocument
  multi-window architecture. Multiple WindowGroup instances and complete
  close/quit confirmation remain to be designed deliberately.
- Untitled projects do not yet have independent crash-recovery packages.
- The snapshot bridge to `MainWindowView` still uses NotificationCenter.
  Typed document callbacks can replace it after UI architecture work.
- Recovery cannot invent missing audio or convert unsupported future
  project formats. User projects must remain unmodified on failure.
- Runtime playback, installed ARIA/Audio Unit restoration, file permissions,
  and macOS user interaction require consolidated Mac acceptance testing.
- GitHub Actions validates debug/release Swift compilation and automated
  tests only; no DAW hardware listening result is implied.

### Build and test

```bash
swift build
swift test --parallel
swift build -c release --product DAWApp
```

Consult the latest `macOS build and tests` workflow result on this branch
for whether the checkpoint passed after the final commit.
