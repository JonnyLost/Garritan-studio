# Studio native graph ownership — first containment milestone

Date: November 13, 2026
Branch: `architecture/studio-independence`
Scope: experimental `CoreAudioBackend` and its `RenderGraph`; default `AVAudioEngine` is unchanged.

## Changes

1. Track create/remove, track gain/pan/mute, plugin unload, and master gain now use the previously established control-thread-only `withDrainedOutput` boundary. The hardware output is stopped and its callbacks drained before render graph dictionaries or node lifetimes are changed. Buffer resize also drains and restarts the output, including restart failure handling.
2. Asynchronous instrument/effect loading uses `withDrainedOutputAsync` to keep callbacks stopped during mutation, configuration and awaited instantiation. The output is restarted in a `defer` whether the operation succeeds or throws. The callback never waits on a lock or performs plugin configuration.
3. Instruments instantiated through `AVAudioUnit` are not directly disposed with `AudioComponentInstanceDispose` on replacement. Their owning wrapper is retained until the replacement has allocated resources and is ready for insertion. Unloading clears all instrument/AVAudioUnit/render block references.
4. Effect slots use optional entries so gaps do not alias the same effect AudioUnit. Replacement disposes the former effect exactly once; unloading retains stable slot indexes and clears the chosen slot without shifting other slots. Effect slot indices are bounded (0–63). Initialization failure disposes the newly created effect.
5. Repaired an earlier transport CI compilation failure: a stale `_isPlaying` reference in the offline bounce guard now uses the atomic `isPlaying` accessor.

## Explicit limitations

- This is **containment**, not an immutable zero-glitch live-graph system. Draining and restarting the output for gain/pan/mute and plugin changes can produce audible interruptions; a later native command/snapshot exchange should replace this model.
- All control operations, including asynchronous loads, **must be serialized by the caller**. A suspended `withDrainedOutputAsync` does not prevent unrelated control code from editing the graph. No new concurrency guarantee is claimed for arbitrary simultaneous UI interactions.
- Live immediate MIDI calls, metronome edits, full render graph ownership, audio buffer bounds and offline bounce interactions still need dedicated safety work.
- Effect processing remains the inherited `AudioUnitRender` path and its signal routing is not validated by this milestone. This change corrects ownership, not every effect's DSP processing.
- This does **not** alter app project persistence, ARIA/Garritan hosting in the default backend, or any other development branch. It is not a claim that all inherited source is independently authored.
- No native macOS runtime verification has been performed here. Require the final GitHub Actions build/tests result and consolidated Mac acceptance before declaring the backend safe or enabling it by default.

## Next gate

Single-owner command queue and immutable graph handoff for low-glitch control changes, Audio Unit hosting safety and effect routing verification, MIDI overflow/note-off protection and real Mac stress testing.
