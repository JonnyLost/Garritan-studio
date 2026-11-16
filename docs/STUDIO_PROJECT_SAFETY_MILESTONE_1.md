# Project safety milestone 1

Base: 7fded2f9b9947cad12baaa31e8c0584bf4bd8024.
Selected recovery and AppKit guard implementations forward-ported from architecture/studio-independence; no engine or DSP changes.

- Completed hidden backups are retained beside project packages. Missing canonical packages recover from a valid completed backup; partial staging is never promoted.
- Failed promotion attempts rollback; if rollback fails the backup remains available.
- File > Recover Previous Version opens a selected hidden backup as an unsaved document. Save As writes a new destination.
- Dirty sessions receive a separate full-package recovery snapshot every 60 seconds, including the existing live AU snapshot. File > Recover Unsaved Project discovers interrupted recovery saves and opens a draft as an unsaved document.
- Close/Quit await the existing Save/Cancel/Don't Save decision. In-flight save, recovery or open prevents teardown.
- Recovery packages and previous versions are intentionally not automatically pruned or deleted. They consume disk space and may contain old music. They can be inspected in Finder; keep them until a newer save is verified.
- Recovery snapshots can fail if referenced external audio disappears; the previous snapshot is preserved and a visible error requests a manual save.
- A crash before the first 60-second snapshot can lose recent work. This is process-crash recovery, not a guarantee against disk failure or sudden power loss.
- Project serialization, identifiers, AU snapshot protocol and legacy JSON decoding remain unchanged.

Validation: macOS workflow runs full debug build, complete tests and optimized DAWApp. No Linux app compilation. New tests cover interrupted saves, failed replacement/rollback, draft survival, legacy JSON, repeated saves and close/quit negotiation. Existing AU and orchestral regressions run in the full suite.

MacBook acceptance: Close/Quit Save/Cancel/Don't Save; edits during async save; force quit after a recovery snapshot and reopen via recovery menu; save/reopen with ARIA and recorded audio; recover previous version and Save As; verify no routing or instrument changes. Multiple SwiftUI windows share AppState as in Alpha 1; exercise close/reopen and quit explicitly.
