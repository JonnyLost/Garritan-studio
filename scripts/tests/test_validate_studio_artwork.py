#!/usr/bin/env python3
"""Standard-library regression tests for approved artwork resource validation."""

import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import validate_studio_artwork as artwork  # noqa: E402


def chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def sample_png(width=256, height=256, color_type=6, include_end=True) -> bytes:
    channels = 4 if color_type == 6 else 3
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    scanlines = (b"\x00" + b"\x00" * (width * channels)) * height
    result = (artwork.PNG_SIGNATURE +
              chunk(b"IHDR", ihdr) +
              chunk(b"IDAT", zlib.compress(scanlines)))
    if include_end:
        result += chunk(b"IEND", b"")
    return result


class ArtworkValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "instrument_test.png"

    def test_valid_rgba_image(self):
        self.path.write_bytes(sample_png())
        report = artwork.read_png(self.path)
        self.assertEqual(report["width"], 256)
        self.assertEqual(report["height"], 256)

    def test_rejects_small_images(self):
        self.path.write_bytes(sample_png(128, 128))
        with self.assertRaisesRegex(ValueError, "too small"):
            artwork.read_png(self.path)

    def test_rejects_non_square_images(self):
        self.path.write_bytes(sample_png(256, 300))
        with self.assertRaisesRegex(ValueError, "square"):
            artwork.read_png(self.path)

    def test_rejects_images_without_alpha(self):
        self.path.write_bytes(sample_png(color_type=2))
        with self.assertRaisesRegex(ValueError, "8-bit RGBA"):
            artwork.read_png(self.path)

    def test_rejects_missing_end_chunk(self):
        self.path.write_bytes(sample_png(include_end=False))
        with self.assertRaisesRegex(ValueError, "end marker"):
            artwork.read_png(self.path)

    def test_rejects_crc_corruption(self):
        bad = bytearray(sample_png())
        bad[16] ^= 1  # Break IHDR while retaining its original checksum.
        self.path.write_bytes(bad)
        with self.assertRaisesRegex(ValueError, "CRC"):
            artwork.read_png(self.path)

    def test_source_identity_lists_are_accessible(self):
        base = artwork.enum_cases(
            artwork.SOURCE / "StudioInstrumentIcon.swift",
            "enum InstrumentIconIdentity:"
        )
        sections = artwork.enum_cases(
            artwork.SOURCE / "StudioInstrumentGroupArtwork.swift",
            "enum StudioInstrumentGroupArtwork:"
        )
        self.assertGreaterEqual(len(base), 144)
        self.assertGreaterEqual(len(sections), 50)
        self.assertIn("mellophone", base)
        self.assertIn("orchestraAndChoir", sections)

    def test_missing_optional_images_are_not_errors(self):
        report, errors = artwork.audit()
        self.assertEqual(errors, [])
        self.assertEqual(report["status"], "valid")


if __name__ == "__main__":
    unittest.main()
