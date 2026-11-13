# Studio — Shared Sample Cache (Sampler + Granular)

Branch: `integration/studio-synth-sampler-bridge` (no merge performed)

## Purpose

The native Studio Sampler and native Granular synthesizer can play the same
recording without decoding it twice or storing independent C++ copies for each
resident instrument zone.

`StudioSharedSampleCache` in DAWCore manages a **64 MiB default LRU budget**.
Cache entries are immutable, decoded Float32 planar stereo/mono PCM identified
by canonical pathname, filesystem file ID, size, modification time and decoded
frame count.

The underlying `StudioSharedPCM` C++ target owns a reference-counted PCM asset:
left channel, right channel (when stereo), and a precomputed mono downmix for
Granular. The Sampler reads the original stereo channels while Granular reads
the precomputed mono buffer. Both engines retain the *same native handle*
using C APIs. They do not copy samples into individual engine-owned vectors.

## Real-time and lifetime guarantees

- All file opens, decode, downmix, allocations, LRU locking, retain/release,
  and cache eviction happen **on control/background threads** before render.
- The Sampler's `ss_add_shared_zone_with_variation` and Granular's
  `sgr_load_shared_pcm_stopped` take their own native references.
- The audio callback reads immutable pointers only. There is no cache lookup,
  mutex, filesystem access or shared-reference counting in its inner loop.
- The LRU may evict a cached handle while instruments still reference it.
  Their native references keep its memory alive until audio callbacks have
  drained and each engine is destroyed.
- If a source file changes, a new cache key creates a new PCM handle without
  changing notes already using the previous decoded revision.
- The explicit `purge()` operation releases cache ownership only, leaving
  active engines intact.
- Cache statistics (hits, misses, entry count and bytes) can be read on the
  control thread for memory and diagnostics work.

## Scope and tradeoffs

Resident Sampler sources (short samples) and Granular files up to its existing
524,288-frame limit share decoded PCM. All existing sampler mappings, key/
velocity zones, round-robin, articulations, ADSR and loops are preserved.

**Long disk-streamed Sampler recordings are deliberately unchanged.** They
continue using the verified bounded attack buffer and background streaming
pages, rather than forcing entire orchestral samples into RAM. Granular can
cache its first 524,288 decoded frames independently for granular processing;
cross-engine sharing of streaming *pages* is a later optimization.

The cache cap counts only assets held by the cache. A currently playing
instrument may retain assets that are no longer in the LRU: those references
are intentionally outside the idle-cache budget. The native PCM includes a
precomputed mono downmix, adding some memory for Sampler-only sources but
avoiding repeated decoding and duplication across multiple Samplers/Granular
layers. A future optimization could derive mono lazily during preparation.

Previous `ss_add_zone_with_variation`, `ss_add_stream_zone`,
`sgr_load_pcm_stopped` and factory source APIs remain compatible. When an
asset cannot be cached, the existing copying or streaming path is used.

## Verification

- Cross-platform C++ AddressSanitizer/UndefinedBehaviorSanitizer:
  `Tests/StudioSharedPCMStandalone/main.cpp` verifies shared allocation,
  simultaneous native playback and safe lifetime across engine destruction.
- macOS Swift/XCTest:
  `Tests/DAWCoreTests/StudioSharedSampleCacheTests.swift` verifies actual
  buffer reuse, LRU eviction, file revision invalidation and audio rendering
  after eviction.
- Existing Sampler, Granular, Synth and DAW tests run via
  `.github/workflows/studio-synth-sampler-bridge.yml`.

No feature branches were merged. The consolidated on-Mac listening and
composing workflow milestone remains separate from automated verification.
