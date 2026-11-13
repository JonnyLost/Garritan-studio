#!/usr/bin/env python3
"""Offline structural check: keep the DAW core independent of optional cloud auth.

Run on macOS with Python 3 and Swift: python3 Tools/check_studio_independence.py
No credentials, network requests or project fixtures are needed for this check.
"""
import json
import os
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"Studio architecture check FAILED: {message}")


manifest = json.loads(subprocess.check_output(
    ["swift", "package", "dump-package"], cwd=ROOT, text=True
))
targets = {target["name"]: target for target in manifest["targets"]}
cloud_auth_enabled = os.environ.get("STUDIO_ENABLE_CLOUD_AUTH") == "1"
require(manifest["name"] == "Studio", "SwiftPM package should be named Studio")
for name in ("DAWCore", "DAWUI", "DAWApp", "StudioCloudAuth", "StudioIdentity", "StudioAI"):
    require(name in targets, f"missing SwiftPM target {name}")

core_deps = json.dumps(targets["DAWCore"].get("dependencies", []))
cloud_deps = json.dumps(targets["StudioCloudAuth"].get("dependencies", []))
ui_deps = json.dumps(targets["DAWUI"].get("dependencies", []))
ai_deps = json.dumps(targets["StudioAI"].get("dependencies", []))
require("Supabase" not in core_deps, "DAWCore must not depend on Supabase")
require("StudioCloudAuth" not in core_deps, "DAWCore must not depend on cloud auth")
require("StudioAI" not in core_deps, "DAWCore must not depend on optional AI")
require("DAWCore" in ai_deps, "StudioAI must depend on DAWCore, never the reverse")
if cloud_auth_enabled:
    require("Supabase" in cloud_deps, "opt-in cloud auth module needs Supabase")
    require("supabase-swift" in json.dumps(manifest["dependencies"]),
            "opt-in mode must resolve the Supabase SDK")
else:
    require("Supabase" not in cloud_deps, "local-only auth must not import Supabase")
    require(not manifest["dependencies"],
            "standard Studio must not require external package dependencies")
require("StudioCloudAuth" in ui_deps, "DAWUI must explicitly import its auth module")
require("StudioIdentity" in ui_deps, "DAWUI must use the shared identity module")
require("StudioAI" in ui_deps, "DAWUI must explicitly import optional AI services")

core_root = ROOT / "DAWCore" / "Sources" / "DAWCore"
for source in core_root.rglob("*.swift"):
    contents = source.read_text(encoding="utf-8")
    require(re.search(r"(?m)^\s*import\s+StudioAI(?:\s|$)", contents) is None,
            f"StudioAI import in DAWCore: {source.relative_to(ROOT)}")
    require(
        re.search(r"(?m)^\s*import\s+Supabase(?:\s|$)", contents) is None,
        f"Supabase SDK import in DAWCore: {source.relative_to(ROOT)}",
    )

require(not list((core_root / "AI").glob("*.swift")),
        "AI services must not live inside DAWCore")
for name in ("DAWChatService.swift", "ClaudeService.swift", "ElevenLabsService.swift",
             "MiniMaxService.swift", "MIDIContextAnalyzer.swift", "ProjectStateSerializer.swift"):
    require((ROOT / "StudioAI" / "Sources" / "StudioAI" / name).is_file(),
            f"missing optional AI implementation: {name}")
require((core_root / "Models" / "StudioCompatibilityExtensions.swift").is_file(),
        "compatibility helpers must remain available from DAWCore")
require(not (core_root / "Auth" / "SupabaseAuthService.swift").exists(),
        "old DAWCore auth service must not be compiled")
require((ROOT / "StudioCloudAuth" / "Sources" / "StudioCloudAuth" /
         "SupabaseAuthService.swift").is_file(),
        "opt-in auth module implementation is missing")
require((ROOT / "StudioCloudAuth" / "Sources" / "StudioCloudAuth" /
         "LocalOnlyAuthService.swift").is_file(),
        "local-only auth adapter is missing")

persistence = (core_root / "Persistence" / "ProjectPersistence.swift").read_text()
require('projectExtension = "dawproj"' in persistence, "legacy project extension changed")
require('projectFileName = "project.json"' in persistence, "legacy project manifest changed")
recording_locations = (core_root / "Persistence" / "StudioRecordingLocations.swift")
require(recording_locations.is_file(), "Studio recording locations are missing")
recording_source = recording_locations.read_text()
require('Studio/Recordings' in recording_source,
        "new Studio recording path missing")
require('MusioCreate/Recordings' in recording_source,
        "legacy managed recording recovery path missing")

with (ROOT / "DAWApp" / "Resources" / "Info.plist").open("rb") as f:
    info = plistlib.load(f)
require(info.get("CFBundleDisplayName") == "Studio", "visible app name is not Studio")
require(info.get("CFBundleIdentifier") == "com.musio.create",
        "legacy bundle identifier changed without migration")
exports = info.get("UTExportedTypeDeclarations", [])
require(any(t.get("UTTypeIdentifier") == "com.musio.create.project"
            for t in exports), "legacy document UTType lost")
require(any("com.musio.create.project" in t.get("LSItemContentTypes", [])
            for t in info.get("CFBundleDocumentTypes", [])),
        "legacy project file association lost")

print("Studio architecture check passed: " +
      ("opt-in cloud compatibility" if cloud_auth_enabled else "local-first native package") +
      ", DAWCore independent of cloud and AI, project identifiers preserved.")
