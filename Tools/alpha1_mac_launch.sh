#!/usr/bin/env bash
# Garritan Studio Alpha 1 — reproducible Mac acceptance launcher.
# Builds the exact CI-green snapshot in an isolated detached worktree.
# Does NOT switch, reset, clean or alter the user's existing checkout.
set -euo pipefail

readonly repo="${HOME}/Developer/Garritan-studio"
readonly checkout="${HOME}/Developer/Garritan-studio-Alpha1"
readonly frozen_branch="checkpoint/studio-alpha1-ci-green-2026-11-14"
readonly frozen_sha="47f6d887be3a5f781d33fb83e98472f2c343e3a1"
readonly log_dir="${HOME}/Library/Logs/GarritanStudio/Alpha1"

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
echo "GitHub CI: https://github.com/JonnyLost/Garritan-studio/actions/runs/43663886947"
echo "Compiling the test app; your usual Studio folder remains untouched."
echo "Build log: $log_dir/build.log"
swift build --product DAWApp 2>&1 | tee "$log_dir/build.log"
echo "Launching Studio Alpha 1. Test with a NEW throwaway project."
echo "Runtime log: $log_dir/runtime.log"
swift run DAWApp 2>&1 | tee "$log_dir/runtime.log"
