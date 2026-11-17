# Alpha 1 Intel Mac runtime crash — isolated triage

**Source candidate:** `integration/studio-alpha1-mac-candidate-2026-11-15` at `5508f35361756e0801fd0501e6e5401dd91c1463`.
**Disposition:** diagnostic safety patch only; do **not** merge without owner approval or mark the runtime crash resolved.

## Observations from the November 17 Mac acceptance

- The app compiled, launched, started AVAudioEngine, connected an instrument track, and loaded the in-process Garritan ARIA AU.
- The console recorded successful MIDI note-on/off routing, native ARIA editor presentation and closing, ARIA state capture, and a project recovery snapshot.
- An orchestral-stage render warned of duplicate `4-Taiko` SwiftUI `ForEach` IDs.
- Several minutes after opening/closing the native editor, the main thread faulted with `EXC_BAD_ACCESS / SIGSEGV` at `0x20`, in `objc_release` while draining an autorelease pool. The trace lacks a frame identifying the object whose lifetime was corrupted.
- A separate Core Audio render thread showed unusually deep nested input-block calls, and earlier logs contained audio-overload warnings. These may merit investigation, but **no cycle or root cause is established** by this report.
- The crash was on macOS 15.7.3, x86-64 Mac mini, with ARIA AU present. CI success on the candidate source did not verify this interactive lifecycle.

## Safety changes in this branch

1. The ordinary track-channel button now opens the existing generic ARIA parameter controls, without asking ARIA to create its original AppKit editor. The **explicit** “Open Original ARIA Player…” advanced action remains available, but must not be used for initial stability acceptance.
2. Stage-guide IDs now include fixed seat pan in addition to name and zone, distinguishing left/right Taiko sections without renaming either label.
3. Audio graph, instrument instances, microphone/reverb routing, MIDI timing, and persistence are deliberately unchanged.

## Verification status and next gate

**Not yet tested on Mac hardware.** The changes are narrowly scoped and require macOS compile/Swift regression validation followed by one disposable-project smoke test.

- Launch, load an ARIA track, open/close the ordinary **Open ARIA Controls** button, play MIDI, save and close; no unsafe native editor should be requested on this path.
- Open the symphony stage: there should be no duplicate `4-Taiko` ID warning.
- Repeat normal transport and project operations. If `objc_release` still faults with the generic editor, inspect plug-in state capture/retention, observer lifetime, and the AVAudioEngine graph; do not automatically blame the native editor.
- Avoid testing the explicit original ARIA editor until a separate controlled lifetime investigation is ready. Do not risk existing sessions.

The input crash reports are user-provided diagnostic evidence, not a reproducible or symbolically root-caused failure. Keep this PR in draft, and keep Alpha 1's last green checkpoint untouched.
