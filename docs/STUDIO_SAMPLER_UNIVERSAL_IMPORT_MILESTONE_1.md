# Universal Instrument Import — Milestone 1: Safe Discovery

Branch: `feature/studio-sampler-native`

This milestone adds `StudioSamplerImportDiscovery`, a bounded, read-only directory
inventory and format classifier. It does **not** add universal format decoding,
ZIP extraction, or UI integration. Existing importers and Alpha 1 routing are unchanged.

## Format routing

- Existing importer candidates: native `.studioinstrument`, SFZ, SF2, GIG,
  EXS/EXS24, and **only the supported legacy subset** of Kontakt NKI.
- Future adapters: Kontakt NKM, NKSF metadata, Decent Sampler DSPRESET/DSLIBRARY.
- Audio for future mapping: WAV, AIFF, CAF, FLAC. Recognition does not imply
  the current sampler decoder can read every codec.
- ZIP: discovery-only; archive extraction and validation are a separate milestone.

## Safety and acceptance

The scanner does not open or parse instrument contents, never follows symbolic
links, does not descend into native instrument packages, and limits entry count
and depth. Results report truncated scans rather than implying completeness.
Tests cover extension routing, nested inventory, symlink avoidance, and limits.

Next milestone: secure ZIP central-directory inspection and bounded extraction,
with traversal, symlink, size, ratio, duplicate-path, and collision defenses;
then preview/convert through existing importers into `.studioinstrument`.
Proprietary encrypted/locked content remains outside the promise of conversion.
