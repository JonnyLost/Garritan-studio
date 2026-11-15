#!/usr/bin/env bash
# Garritan Studio Alpha 1 — safe detached Mac acceptance launch.
# Leaves your normal working branch and project files untouched.
set -euo pipefail

repo="${HOME}/Developer/Garritan-studio"
checkout="${HOME}/Developer/Garritan-studio-Alpha1"
candidate="integration/studio-alpha1-consolidated-2026-11-14"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift / Xcode command-line tools are required on this Mac." >&2
  exit 1
fi
if [[ ! -d "$repo/.git" && ! -f "$repo/.git" ]]; then
  echo "Existing Git checkout not found at $repo; nothing was modified." >&2
  exit 1
fi
if [[ -e "$checkout" ]]; then
  echo "The separate Alpha 1 folder already exists at $checkout." >&2
  echo "Nothing was overwritten. Open a terminal in that folder to continue." >&2
  exit 1
fi

cd "$repo"
git fetch origin
git worktree add --detach "$checkout" "origin/$candidate"
cd "$checkout"
echo "Alpha 1 exact source commit: $(git rev-parse HEAD)"
echo "Building and launching the candidate. The normal Studio checkout is unchanged."
swift build --product DAWApp
swift run DAWApp
