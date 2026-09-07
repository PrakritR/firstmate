#!/usr/bin/env bash
# Shared no-mistakes gate helpers for PropPlane ladder promotion scripts.
set -eu

fm_proplane_assert_no_mistakes_completed() {
  local git_root=$1
  local status_out
  if ! status_out="$(cd "$git_root" && no-mistakes axi status 2>&1)"; then
    echo "proplane-no-mistakes-gate: could not read no-mistakes status — refusing to continue" >&2
    return 1
  fi
  if printf '%s' "$status_out" | grep -qiE "awaiting_approval|awaiting_agent|parked"; then
    echo "proplane-no-mistakes-gate: no-mistakes is PARKED at a gate — refusing to continue." >&2
    echo "  Drive it with: no-mistakes axi respond --action <approve|fix|skip> [--findings <ids>]" >&2
    return 1
  fi
  if printf '%s' "$status_out" | grep -qiE "^[[:space:]]*status:[[:space:]]*(running|failed|cancelled)"; then
    echo "proplane-no-mistakes-gate: no-mistakes run did not pass — refusing to continue." >&2
    printf '%s\n' "$status_out" | head -20 >&2
    return 1
  fi
  return 0
}

fm_proplane_run_no_mistakes() {
  local git_root=$1
  local branch=$2
  local intent=$3
  local dry_run=${4:-0}

  echo "== no-mistakes validation on $branch =="
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY no-mistakes axi run --intent ... --skip=push,pr,ci"
    return 0
  fi
  (
    cd "$git_root"
    git checkout "$branch"
    no-mistakes axi run \
      --intent "$intent" \
      --skip=push,pr,ci
  )
}
