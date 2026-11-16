#!/usr/bin/env python3
"""Validate approved, local Cinematic Atelier image resources.

Usage:
  python3 scripts/validate_studio_artwork.py
  python3 scripts/validate_studio_artwork.py --report /tmp/artwork-report.json

Only artwork actually copied into DAWUI/Resources/InstrumentArtwork is checked.
The production app intentionally supports zero bundled PNGs while art is being
approved: all missing files fall back to native SwiftUI drawings. Invalid or
unrecognized PNGs fail the check before they can ship.
"""

import argparse
import json
import re
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "DAWUI/Sources/DAWUI/Views/Shared"
ASSETS = ROOT / "DAWUI/Sources/DAWUI/Resources/InstrumentArtwork"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MIN_DIMENSION = 256
MAX_DIMENSION = 2048
MAX_BYTES = 6 * 1024 * 1024


def enum_cases(source: Path, declaration: str) -> set[str]:
    content = source.read_text(encoding="utf-8")
    start = content.find(declaration)
    if start < 0:
        raise ValueError(f"missing enum declaration {declaration} in {source}")
    body_start = content.find("{", start) + 1
    end = content.find("    var accessibilityLabel", body_start)
    if end < 0:
        raise ValueError(f"missing enum termination marker in {source}")
    body = content[body_start:end]
    result: set[str] = set()
    for match in re.finditer(r"^\s*case\s+([^\n]+)$", body, flags=re.MULTILINE):
        for fragment in match.group(1).split(","):
            name = fragment.strip()
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name):
                raise ValueError(f"unexpected case syntax: {name}")
            result.add(name)
    if not result:
        raise ValueError(f"empty enum {declaration}")
    return result


def read_png(path: Path) -> dict:
    """Verify real PNG structure, CRCs, bounded decoding and artwork size."""
    size = path.stat().st_size
    if size > MAX_BYTES:
        raise ValueError(f"file exceeds {MAX_BYTES // (1024 * 1024)} MiB budget")
    blob = path.read_bytes()
    if not blob.startswith(PNG_SIGNATURE):
        raise ValueError("invalid PNG signature")

    pos = 8
    seen_header = False
    seen_end = False
    idat_parts = []
    width = height = None
    while pos + 12 <= len(blob):
        length = struct.unpack(">I", blob[pos:pos + 4])[0]
        kind = blob[pos + 4:pos + 8]
        payload_start = pos + 8
        payload_end = payload_start + length
        if payload_end + 4 > len(blob):
            raise ValueError("truncated PNG chunk")
        payload = blob[payload_start:payload_end]
        crc = struct.unpack(">I", blob[payload_end:payload_end + 4])[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise ValueError(f"bad CRC for {kind.decode('ascii', errors='replace')}")
        if not seen_header and kind != b"IHDR":
            raise ValueError("PNG must start with IHDR")
        if kind == b"IHDR":
            if seen_header or length != 13:
                raise ValueError("duplicate or invalid PNG IHDR")
            width, height, depth, color_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", payload)
            )
            if width < MIN_DIMENSION or height < MIN_DIMENSION:
                raise ValueError(
                    f"too small ({width}x{height}); minimum {MIN_DIMENSION}px"
                )
            if width > MAX_DIMENSION or height > MAX_DIMENSION:
                raise ValueError(
                    f"too large ({width}x{height}); maximum {MAX_DIMENSION}px"
                )
            if width != height:
                raise ValueError(f"expected square canvas, got {width}x{height}")
            if (depth, color_type, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError("expected non-interlaced 8-bit RGBA PNG")
            seen_header = True
        elif kind == b"IDAT":
            idat_parts.append(payload)
        elif kind == b"IEND":
            if length != 0:
                raise ValueError("invalid PNG end marker")
            seen_end = True
            pos = payload_end + 4
            break
        pos = payload_end + 4

    if not seen_header or not idat_parts or not seen_end or pos != len(blob):
        raise ValueError("missing PNG image data, end marker or unexpected trailing data")

    # Bound decompression so damaged or crafted images cannot consume arbitrary
    # memory in CI. Non-interlaced RGBA has one filter byte per scanline.
    stride = width * 4
    expected = height * (stride + 1)
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(b"".join(idat_parts), expected + 1)
    if len(pixels) != expected or not decoder.eof or decoder.unconsumed_tail:
        raise ValueError("invalid or unexpectedly large PNG pixel data")
    if any(pixels[row * (stride + 1)] > 4 for row in range(height)):
        raise ValueError("invalid PNG scanline filter type")
    return {"width": width, "height": height, "bytes": size}


def audit() -> tuple[dict, list[str]]:
    individuals = enum_cases(
        SOURCE / "StudioInstrumentIcon.swift",
        "enum InstrumentIconIdentity:"
    )
    ensembles = enum_cases(
        SOURCE / "StudioInstrumentGroupArtwork.swift",
        "enum StudioInstrumentGroupArtwork:"
    )
    # The declared enums include fallback icons as well as musical instruments.
    expected = {f"instrument_{identity}" for identity in individuals}
    expected |= {f"ensemble_{identity}" for identity in ensembles}

    installed = []
    errors = []
    if not ASSETS.is_dir():
        errors.append(f"missing resource directory: {ASSETS}")
    else:
        for path in sorted(ASSETS.iterdir()):
            if path.name == "README.md":
                continue
            if not path.is_file() or path.suffix.lower() != ".png":
                errors.append(f"unexpected file in artwork resource folder: {path.name}")
                continue
            if path.stem not in expected:
                errors.append(f"unknown artwork key: {path.name}")
                continue
            try:
                metadata = read_png(path)
            except (OSError, ValueError, struct.error) as exc:
                errors.append(f"{path.name}: {exc}")
                continue
            installed.append({"asset": path.name, "key": path.stem, **metadata})

    valid = {row["key"] for row in installed}
    report = {
        "scope": "Local, individually approved PNG resources only",
        "base_icon_identity_count": len(individuals),
        "ensemble_identity_count": len(ensembles),
        "approved_image_count": len(installed),
        "installed_images": installed,
        "missing_optional_images": sorted(expected - valid),
        "errors": errors,
        "status": "invalid" if errors else "valid"
    }
    return report, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", help="Optional JSON report path")
    args = parser.parse_args()
    report, errors = audit()
    if args.report:
        Path(args.report).write_text(
            json.dumps(report, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8"
        )
    print(
        f"Studio artwork: {report['base_icon_identity_count']} base identities, "
        f"{report['ensemble_identity_count']} section identities, "
        f"{report['approved_image_count']} approved PNGs, "
        f"{len(errors)} errors"
    )
    for error in errors:
        print(f"ERROR: {error}")
    if not report["approved_image_count"]:
        print("INFO: No approved PNGs installed; native vector fallbacks remain in use.")
    raise SystemExit(1 if errors else 0)


if __name__ == "__main__":
    main()
