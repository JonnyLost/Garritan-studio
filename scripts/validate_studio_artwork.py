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
    # PNG IHDR is at byte 16, following an 8-byte signature and 8-byte chunk
    # prefix. This avoids PIL/image dependencies in GitHub Actions.
    with path.open("rb") as fp:
        header = fp.read(33)
    if len(header) < 33 or not header.startswith(PNG_SIGNATURE):
        raise ValueError("invalid or truncated PNG header")
    if header[12:16] != b"IHDR" or struct.unpack(">I", header[8:12])[0] != 13:
        raise ValueError("expected PNG IHDR")
    width, height, depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", header[16:29])
    if width < MIN_DIMENSION or height < MIN_DIMENSION:
        raise ValueError(f"too small ({width}x{height}); minimum {MIN_DIMENSION}px")
    if width > MAX_DIMENSION or height > MAX_DIMENSION:
        raise ValueError(f"too large ({width}x{height}); maximum {MAX_DIMENSION}px")
    if width != height:
        raise ValueError(f"expected square canvas, got {width}x{height}")
    if color_type != 6 or depth != 8:
        raise ValueError("expected 8-bit RGBA with transparent-capable pixels")
    size = path.stat().st_size
    if size > MAX_BYTES:
        raise ValueError(f"file exceeds {MAX_BYTES // (1024 * 1024)} MiB budget")
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
