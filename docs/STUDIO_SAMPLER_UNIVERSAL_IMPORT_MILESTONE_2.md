# Universal Instrument Import — Milestone 2: ZIP Inventory

Adds a bounded, read-only ZIP central-directory scanner for user-selected
archives. The scanner lists instrument mappings and audio candidates without
extracting archive contents or changing source files.

Safeguards: rejects encrypted and unsupported compression entries, ZIP64 and
multi-disk metadata, path traversal, absolute paths, backslashes, control
characters, symlink entries, case-insensitive duplicate names, oversized
central directories, excessive entry counts, and excessive declared output
sizes. Does not promise to validate the integrity of compressed payloads;
actual extraction must separately verify CRC and enforce *observed* byte
limits. ZIP headers are untrusted.

Next milestone: isolated extraction of approved entries with observed byte
limits and CRC verification, then existing importer preview, user approval,
and native package creation. Do not use a blanket ZIP extraction API that
could follow archive paths or overwrite existing files.

This milestone is not integrated into Alpha 1.
