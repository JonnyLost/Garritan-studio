#!/usr/bin/env bash
# Garritan Studio Alpha 1 — combined candidate launcher (explicit tested SHA required).
# Builds the exact CI-green snapshot in an isolated detached worktree.
# Does NOT switch, reset, clean or alter the user's existing checkout.
set -euo pipefail

readonly repo="${HOME}/Developer/Garritan-studio"
readonly checkout="${HOME}/Developer/Garritan-studio-Alpha1-${1:-missing}"
readonly frozen_branch="integration/studio-alpha1-mac-candidate-2026-11-15"
readonly frozen_sha="${1:?Usage: bash Tools/alpha1_candidate_mac_launch.sh FULL_TESTED_COMMIT_SHA}"
[[ "$frozen_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Expected a full 40-character commit SHA." >&2; exit 1; }
readonly log_dir="${HOME}/Library/Logs/GarritanStudio/Alpha1-${frozen_sha}"

die() {
  printf 'Alpha 1 launch stopped safely: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || die "This acceptance build requires macOS."
command -v git >/dev/null 2>&1 || die "Git is not installed."
command -v swift >/dev/null 2>&1 || die "Xcode Command Line Tools / Swift are missing."
[[ -d "$repo" ]] || die "Studio checkout not found at $repo."
git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 ||
  die "$repo is not a Git checkout."
# Fetch only the immutable acceptance checkpoint; no branch checkout or pull.
git -C "$repo" fetch --no-tags origin \
  "refs/heads/${frozen_branch}:refs/remotes/origin/${frozen_branch}"
actual="$(git -C "$repo" rev-parse "refs/remotes/origin/${frozen_branch}^{commit}")"
[[ "$actual" == "$frozen_sha" ]] ||
  die "The acceptance checkpoint changed; expected $frozen_sha, found $actual. Nothing was built."

if [[ -e "$checkout" ]]; then
  [[ -d "$checkout" && ! -L "$checkout" ]] ||
    die "An existing file or symlink occupies $checkout."
  checkout_sha="$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" ||
    die "The folder $checkout exists but is not a valid Git checkout."
  checkout_root="$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null)"
  git -C "$repo" worktree list --porcelain | grep -Fxq "worktree $checkout" ||
    die "The existing Alpha 1 directory is not an owned worktree of Studio."
  [[ "$checkout_root" == "$checkout" && "$checkout_sha" == "$frozen_sha" ]] ||
    die "The existing Alpha 1 folder has different files/commit. It was not modified."
  [[ -z "$(git -C "$checkout" status --porcelain)" ]] ||
    die "Existing Alpha 1 worktree has local changes; inspect them before relaunching."
  echo "Reusing the unchanged CI-green Alpha 1 worktree."
else
  git -C "$repo" worktree add --detach "$checkout" "$frozen_sha"
fi

mkdir -p "$log_dir"
cd "$checkout"
echo "Studio Alpha 1 validation checkpoint: $(git rev-parse HEAD)"
echo "Verify successful CI for the printed SHA before composing. GitHub CI: https://github.com/JonnyLost/Garritan-studio/actions?query=branch%3Aintegration%2Fstudio-alpha1-mac-candidate-2026-11-15"
echo "Compiling the test app; your usual Studio folder remains untouched."
echo "Build log: $log_dir/build.log"
swift build --product DAWApp 2>&1 | tee "$log_dir/build.log"
echo "Launching Studio Alpha 1. Test with a NEW throwaway project."
echo "Runtime log: $log_dir/runtime.log"
swift run --skip-build DAWApp 2>&1 | tee "$log_dir/runtime.log"
