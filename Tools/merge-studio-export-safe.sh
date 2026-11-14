#!/usr/bin/env bash
# Non-destructive, pinned-source reconciliation of post-fork audio export fixes.
set -euo pipefail

source_sha="1f9903da8a0240a7c390180f998d8896ed5fe341"
conflict_path="DAWApp/Sources/DAWApp/DAWApp.swift"

git config user.name "Studio integration bot"
git config user.email "studio-integration@users.noreply.github.com"
# Markdown source intentionally uses two spaces for hard line breaks.
git config core.whitespace "-blank-at-eol"
git fetch origin "feature/studio-export-engine"

if git merge-base --is-ancestor "$source_sha" HEAD; then
  echo "The pinned export engine commit is already present."
  echo "SKIP_COMMIT=true" >> "${GITHUB_ENV:-/dev/null}"
  exit 0
fi

if git merge --no-commit --no-ff "$source_sha" >/tmp/studio-export-merge.log 2>&1; then
  echo "Export engine merged without content conflicts."
else
  conflicts="$(git diff --name-only --diff-filter=U)"
  if [[ "$conflicts" != "$conflict_path" ]]; then
    echo "Unexpected conflict set; refusing to complete the integration:" >&2
    printf '%s\n' "$conflicts" >&2
    cat /tmp/studio-export-merge.log >&2
    exit 1
  fi

  # This file was hand-reconciled on the staging branch before the merge.
  # The staging copy contains BOTH the recent MIDI file menu and Export Audio & Stems.
  git checkout --ours -- "$conflict_path"
  git add -- "$conflict_path"
fi

grep -Fq 'Export Audio & Stems' "$conflict_path"
grep -Fq 'Import MIDI as New Project' "$conflict_path"
grep -Fq 'Export MIDI' "$conflict_path"
grep -Fq 'showStudioExport' "$conflict_path"

if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
  echo "Unresolved files remain; refusing to continue." >&2
  exit 1
fi

git diff --cached --check
echo "Export and MIDI commands both preserved; all conflict markers resolved."
