# Approved Cinematic Atelier Artwork Assets

This folder is the local resource destination for **approved, individual** browser illustrations.

- Name PNGs `instrument_<InstrumentIconIdentity case>.png` for solo instruments, or `ensemble_<StudioInstrumentGroupArtwork rawValue>.png` for sections/ensembles.
- Keep each image transparent, with no instrument name or UI labels baked into the pixels.
- Use original illustrations and confirm accuracy, ownership and visual approval before adding any files.
- Export 2x versions appropriate for the largest browser size (~320 px canvas) while keeping file sizes low and decoding efficient.
- The SwiftUI artwork card falls back to the native vector drawing whenever a PNG is absent or corrupt; track icons remain native vectors for crisp small-scale presentation.
- This README is not an image; no final approved watercolor artwork has been shipped yet.
