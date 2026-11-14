# Studio — Off-Graph Audio Unit Preparation Milestone

**Date:** November 13, 2026
**Branch:** `architecture/studio-independence`
**Scope:** experimental native Core Audio backend only.

## Implementation

- `RenderGraph.prepareInstrument` asynchronously instantiates and configures an *unattached* AVAudioUnit, sets its stream format and maximum render slice size, allocates render resources and obtains its render block. It does not alter the active track dictionary or the published render-route snapshot.
- `RenderGraph.installInstrument` performs the short synchronous ownership transfer after output callbacks are fully drained. The old AVAudioUnit remains owned by the graph until the replacement is installed. If the original track disappears during asynchronous preparation, installation fails and the prepared owner is released without modifying the active graph.
- `RenderGraph.prepareEffect` creates, configures and initializes an independent effect instance before touching the graph. Its `PreparedEffect` owner disposes the instance if preparation/install fails, or transfers it exactly once into the selected slot during `installEffect`.
- `CoreAudioBackend` now prepares instruments and effects while hardware playback can continue, then invokes `withDrainedOutputResult` solely for the synchronous graph swap and snapshot publication. This removes the earlier potentially long `await AVAudioUnit.instantiate` from the hardware stop/restart interval.
- Added a regression test confirming invalid effect preparation does not change live graph membership or its generation.
- The preceding render-route-snapshot milestone CI run `43543201488` **passed**. Verify the final commit's macOS CI independently.

## Boundaries and risks

- Preparing an Audio Unit while the *current* AU renders is not the same as crossfading live route snapshots: actual topology installation still drains and restarts the hardware output to protect AU and buffer lifetime.
- The calling domain **must serialize control commands and plugin-load completions**. This milestone does not resolve concurrent UI operations while an async AU instantiate suspends. Do not enable native Core Audio by default until a single-owner executor and safe graph reclamation mechanism exist.
- The experimental effect signal path remains unverified and is not made correct merely by isolating AU creation. The default AVAudioEngine backend and Garritan/ARIA routing are intentionally unchanged.
- Preparing an effect may trigger third-party component code and can be expensive; it runs only on the calling control context, never the render callback. A dedicated worker/executor should own preparation in the final architecture.
- This change does not establish hard real-time safety for every Swift object in the callback, device reconfiguration, full MIDI note-off safety or offline-bounce exclusivity.

## Next milestone

Introduce a serialized control owner that arbitrates async plugin preparation/commit against seek, stop, buffer reconfiguration and offline bounce. Then implement separately allocated topology snapshots with bounded publication and safe retirement, followed by comprehensive Mac hardware tests and instrument/effect routing validation.

No branch merge performed.
