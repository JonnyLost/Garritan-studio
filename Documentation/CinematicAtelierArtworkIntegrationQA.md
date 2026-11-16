# Cinematic Atelier — artwork integration and review QA

**Status:** development / approval pipeline, 2026-11-16. This is not the final approved watercolor collection.  
**Branch:** `feature/studio-gui-refinement`; do not merge into Alpha 1 without explicit approval.

## What is implemented

1. **Native vector fallback:** `StudioInstrumentIcon` draws each physical instrument or representative ensemble locally, without disk I/O, third-party plugins or network access. It remains the track-header icon at small sizes.
2. **Optional approved browser art:** `StudioInstrumentArtworkCard` looks for bundled `instrument_<case>.png` or `ensemble_<case>.png` through `StudioInstrumentArtworkAssets`. If the image has not been installed, the native drawing remains visible.
3. **MacBook memory safeguard:** the image cache is capped to 48 entries / an estimated 48 MiB, and missing image keys are cached to avoid repeated bundle searches on UI redraws.
4. **Complete local review gallery:** `StudioArtworkReviewGallery.swift`, available in Xcode Debug Previews, enumerates every instrument and every section using the *actual SwiftUI vector renderer* (not an AI concept poster). It has toggles for 24 pt track icons, 88 pt browser icons and the existing Studio icon collections; it does not appear in release builds.
5. **Automated asset contract:** `scripts/validate_studio_artwork.py` enumerates all declared Swift instrument and section identities, checks optional PNG filenames, reads/validates PNG structure and CRCs, bounds pixel decoding, requires square noninterlaced 8-bit RGBA at 256–2048 px and a 6 MiB maximum file size. **Absent approved images are allowed**, unrecognized/corrupt images are failures. The validator and its Python tests run in macOS CI.
6. **CI inventory artifact:** The `studio-artwork-inventory` workflow artifact reports all identity keys, installed PNGs and missing optional artwork. This is a review tool, not a claim that every Garritan preset has been classified.

## Reviewing every Studio drawing

In Xcode, open `DAWUI/Sources/DAWUI/Views/Shared/StudioArtworkReviewGallery.swift` and select the **Studio Artwork — All identities** Preview. The gallery provides:

- All declared base instrument/family identities — currently **144**, including generic fallbacks
- All declared solo-distinct section/ensemble identities — currently **50**
- Two size modes (24 pt track and 88 pt browser) and appearance collections

This gallery is not a running production-app feature; it is a QA-only design surface for an instrument-by-instrument signoff. No user Mac testing is required until a consolidated milestone.

## Installing approved artwork

1. Create or approve **one anatomically correct instrument illustration** for each distinct physical instrument; separately approve representative grouped art for section and mixed-layer categories.
2. Export PNG with a **square transparent canvas**, 256–2048 px per side, 8-bit RGBA, noninterlaced, under 6 MiB. A 640×640 px master is typically sufficient for a 320 pt 2× browser card; inspect the actual app size before standardizing all assets.
3. Save an individual approved image as `DAWUI/Sources/DAWUI/Resources/InstrumentArtwork/instrument_mellophone.png` or `ensemble_mellophones.png`. The exact keys are listed in the CI inventory JSON.
4. Run `python3 -m unittest discover -s scripts/tests -p 'test_validate_studio_artwork.py'` then `python3 scripts/validate_studio_artwork.py --report artwork-inventory.json`.
5. Verify that the browser displays installed PNGs, smaller track icons continue using vector drawings, VoiceOver labels are accurate, and no audio/MIDI behavior has changed.
6. Preserve owner/designer approval and source/rights notes in the artwork review before shipping.

## Outstanding release gates

- CI must pass at the current head; previous successful CI is not proof of the latest changes.
- Artwork concepts displayed in chat have **not** been separated into individually verified PNGs or added as approved production assets. Do not use text-filled contact sheets in the app.
- GPO5/Instant Orchestra full program inventories and future World/Jazz/Band libraries are not exhaustively audited without the actual installed bank XML.
- Anatomy review is necessary for woodwind variants, curved saxophones, large brass and percussion forms; AI illustrations are concepts, not a substitute for validation.
- Alpha 1 integration requires separate approval and one consolidated Mac acceptance milestone.
