#!/usr/bin/env bash
# Deterministic, guarded stage + MIDI integration. Modifies only the disposable
# checkout; callers decide whether to publish after passing all macOS gates.
set -euo pipefail

source_sha="864d26bdc133403678af8b861470544461ca0536"
conflict_file="DAWUI/Sources/DAWUI/Views/MainWindowView.swift"
git config user.name "Studio CI Integration"
git config user.email "studio-ci@users.noreply.github.com"
git config core.whitespace "-blank-at-eol"
git fetch origin "fix/studio-virtual-microphone-routing-2026-11-14"

if git merge-base --is-ancestor "$source_sha" HEAD; then
  echo "Pinned microphone branch already integrated."
  echo "STUDIO_MIC_ALREADY_MERGED=true" >> "${GITHUB_ENV:-/dev/null}"
  exit 0
fi

if git merge --no-commit --no-ff "$source_sha" >/tmp/studio-mic-merge.log 2>&1; then
  echo "Mic branch merged cleanly; no conflicts to reconcile."
else
  conflicts="$(git diff --name-only --diff-filter=U)"
  if [[ "$conflicts" != "$conflict_file" ]]; then
    echo "Unexpected conflict set, refusing to integrate:" >&2
    printf '%s\n' "$conflicts" >&2
    cat /tmp/studio-mic-merge.log >&2
    exit 1
  fi

  python3 - <<'PY'
from pathlib import Path
import re
path = Path("DAWUI/Sources/DAWUI/Views/MainWindowView.swift")
content = path.read_text()
pattern = re.compile(r"(?ms)^<<<<<<< HEAD\n(.*?)^=======\n(.*?)^>>>>>>> [^\n]+\n")
found = list(pattern.finditer(content))
if len(found) != 5:
    raise SystemExit(f"Expected exactly 5 Rooms/Ostinato conflict hunks; found {len(found)}")

fixed = []
for match in found:
    ours, rooms = match.group(1), match.group(2)
    if 'if showInstrumentWorkspace ||' in ours and 'showRoomAcousticsWorkspace' in rooms:
        result = ours.replace('showStageWorkspace || showArticulationsWorkspace',
                              'showStageWorkspace || showRoomAcousticsWorkspace || showArticulationsWorkspace')
    elif 'workspaceButton("Ostinato"' in ours and 'workspaceButton("Piano Roll"' in rooms:
        result = ours.replace('!showStageWorkspace && !showArticulationsWorkspace',
                              '!showStageWorkspace && !showRoomAcousticsWorkspace && !showArticulationsWorkspace')
    elif '} else if showOstinatoWorkspace {' in ours and '} else if showRoomAcousticsWorkspace {' in rooms:
        # Keep BOTH complete workspace branches. The shared continuation
        # closes the Rooms condition after its VStack, as it did originally.
        result = ours + rooms
    elif 'get: { viewModel.showPianoRoll &&' in ours and 'showRoomAcousticsWorkspace' in rooms:
        result = ours.replace('!showStageWorkspace && !showChannelWorkspace',
                              '!showStageWorkspace && !showRoomAcousticsWorkspace && !showChannelWorkspace')
    elif 'get: { viewModel.showMixer &&' in ours and 'showRoomAcousticsWorkspace' in rooms:
        result = ours.replace('!showStageWorkspace && !showChannelWorkspace',
                              '!showStageWorkspace && !showRoomAcousticsWorkspace && !showChannelWorkspace')
    else:
        raise SystemExit('Unrecognized conflict hunk: refusing to drop any workspace changes')
    if result == ours and 'showRoomAcousticsWorkspace' not in ours:
        raise SystemExit('Rooms integration was not applied to conflicting content')
    fixed.append(result)

it = iter(fixed)
merged = pattern.sub(lambda _: next(it), content)
assert all(x not in merged for x in ('<<<<<<< HEAD', '\n=======\n', '\n>>>>>>> '))
assert 'OstinatoWorkspaceView(viewModel: viewModel)' in merged
assert 'StudioRoomAcousticsWorkspaceView(viewModel: viewModel)' in merged
assert '.modifier(StudioExportSheetModifier(viewModel: viewModel))' in merged
path.write_text(merged)
print("Reconciled all five exact Rooms/Ostinato UI conflict hunks.")
PY
  git add "$conflict_file"
fi

remaining="$(git diff --name-only --diff-filter=U)"
if [[ -n "$remaining" ]]; then
  echo "Unresolved conflicts: $remaining" >&2
  exit 1
fi
git diff --cached --check
grep -q 'OstinatoWorkspaceView(viewModel: viewModel)' "$conflict_file"
grep -q 'StudioRoomAcousticsWorkspaceView(viewModel: viewModel)' "$conflict_file"
grep -q 'StudioExportSheetModifier(viewModel: viewModel)' "$conflict_file"
echo "Both workspaces and the audio export sheet retained; no unresolved conflicts."
