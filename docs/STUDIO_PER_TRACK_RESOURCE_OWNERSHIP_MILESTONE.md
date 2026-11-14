# Studio — Per-Track Render Resource Ownership

**Date:** November 13, 2026
**Branch:** `architecture/studio-independence`
**Scope:** Experimental native Core Audio RenderGraph only. No production AVAudioEngine or Garritan/ARIA changes.

## Completed

- Introduced `TrackScratchBuffers`: each track owns its preallocated stereo buffers via a reference-counted lifetime object. Its deinitializer releases both fully initialized buffers on the **control side** once the last snapshot using the track has retired.
- Introduced `EffectLifetime`: each raw `AudioUnit` effect is disposed exactly once by its owner, not manually disposed during track removal and again by a retired route. Sparse slots reference optional effect owners rather than unowned raw Audio Unit handles.
- Moved `AVAudioUnit` ownership into `TrackNode.instrumentOwner`; track instances now retain both wrapper and underlying render block together. Removed the parallel `avAudioUnits` ownership dictionary.
- Track removal simply removes its control-side dictionary entry and atomically publishes updated route membership; cleanup is delayed by the existing reader-counted snapshot exchange, and happens on the control thread.
- Introduced `canRemoveEmptyTrackLive` and updated `CoreAudioBackend.removeTrack` to publish removal **without hardware restart** only if a track has neither instrument nor effects. A nonempty processing route still uses the guarded callback drain to protect shared plugin state.
- Buffer-size changes swap each track's owned scratch storage only inside the preexisting hardware-drained control boundary. Rendering checks scratch frame capacity before writing.
- Added tests for generation changes and empty-track resource recreation, plus creating/removing empty routes while render callbacks read snapshots.

## Architectural safety boundary

The live mutation scope is deliberately **empty-track addition and removal**. Instrument replacement, raw effects, loaded-track removal and buffer resizing still drain output, because the `TrackNode` object contains mutable instrument/effect fields, and a prepared snapshot may still share a plugin instance with its predecessor. A resource owner alone does not make an AU render block safely reentrant.

`AVAudioUnit` and effect owners stay alive through the shared track's ownership and the reader-counted render snapshots. This is an important foundation for immutable per-generation processing routes, but not yet a complete glitch-free AU hot swap.

No callback-side locks, file I/O, or manual Audio Unit disposal were introduced. Cleanup is performed only from the control-side snapshot retirement path. The experimental plugin effect signal chain and third-party Audio Unit behavior remain unvalidated.

## Acceptance

- macOS debug/release builds, Swift tests and opt-in cloud compatibility checks must pass on the final branch commit.
- Native Core Audio remains opt-in until consolidated Mac orchestral playback, rapid route edits, mixed AUv2/AUv3 lifetime testing, audio exports and device changes have been validated.
- Do not merge without product-owner authorization.

## Next milestone

Make track processing routes immutable per graph generation, including independently prepared AU and effect chains with safe handoff and non-reentrant render ownership. After that, pursue low-glitch live Audio Unit replacement and formalize effect rendering, plus hardware stress testing.
