#!/usr/bin/env bash
# Sync PropPlane agent sandboxes from origin/prakrit and refresh localhost review servers.
#
# Standing captain order (2026-07-28): whenever origin/prakrit moves, each keeper
# sandbox (claude-1, cursor-1, cursor-2, codex-1, codex-2) receives prakrit locally, pushes
# its branch, and restarts its dev server. After an agent promotes into prakrit, use
# --reset-from-prakrit so sandboxes whose tip is already contained in prakrit match
# integration exactly. Lanes with unique commits ahead are never hard-reset — they
# merge prakrit instead (see sync_sandbox).
#
# Usage:
#   fm-prakrit-sync-agent-branches.sh                    # sync all sandboxes (no dev-server restart)
#   fm-prakrit-sync-agent-branches.sh cursor-1           # one branch
#   fm-prakrit-sync-agent-branches.sh --reset-from-prakrit
#   fm-prakrit-sync-agent-branches.sh --dry-run
#   fm-prakrit-sync-agent-branches.sh --restart         # restart dev servers for branches synced here
#   fm-prakrit-sync-agent-branches.sh --restart --all   # restart every synced branch (memory-heavy)
#   fm-prakrit-sync-agent-branches.sh --no-restart      # explicit no restart (default)
#   fm-prakrit-sync-agent-branches.sh --no-push
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

DRY_RUN=0
NO_RESTART=1
RESTART_ALL=0
NO_PUSH=0
RESET_FROM_PRAKRIT=0
FORCE=0
ONLY_BRANCH=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --restart) NO_RESTART=0 ;;
    --all) RESTART_ALL=1 ;;
    --no-push) NO_PUSH=1 ;;
    --reset-from-prakrit) RESET_FROM_PRAKRIT=1 ;;
    --force) FORCE=1 ;;
    --help|-h)
      echo "usage: fm-prakrit-sync-agent-branches.sh [--dry-run] [--restart] [--all] [--no-restart] [--no-push] [--reset-from-prakrit] [--force] [branch]"
      echo "  default: git sync only — dev servers are not restarted (use --restart to opt in)"
      echo "  --restart  restart localhost for each branch synced in this run"
      echo "  --all      with --restart, restart every synced branch; without [branch], same as all"
      echo "  --reset-from-prakrit  request hard-reset to origin/prakrit; IGNORED unless"
      echo "                        FM_ALLOW_PRAKRIT_HARD_RESET=1 is also set. Even then,"
      echo "                        only resets when the sandbox tip is already contained"
      echo "                        in prakrit; otherwise merges (never destroys unique commits)."
      echo "  --force               CAPTAIN-AUTHORIZED ONLY: discard uncommitted sandbox work"
      exit 0
      ;;
    *)
      if [ -n "$ONLY_BRANCH" ]; then
        echo "unknown argument: $arg" >&2
        exit 2
      fi
      ONLY_BRANCH=$arg
      ;;
  esac
done

should_restart_branch() {
  local branch=$1
  [ "$NO_RESTART" -eq 0 ] || return 1
  if [ -n "$ONLY_BRANCH" ]; then
    [ "$branch" = "$ONLY_BRANCH" ]
    return
  fi
  [ "$RESTART_ALL" -eq 1 ]
}

GIT_ROOT=$(fm_proplane_agent_git_root) || {
  echo "proplane-prakrit-sync: missing GIT_ROOT in $FM_PROPLANE_AGENT_CONFIG" >&2
  exit 1
}
[ -d "$GIT_ROOT/.git" ] || {
  echo "proplane-prakrit-sync: not a git repo: $GIT_ROOT" >&2
  exit 1
}

run_git() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY git -C $*"
    return 0
  fi
  git -C "$@"
}

ensure_worktree() {
  local branch=$1 worktree=$2
  if [ -d "$worktree/.git" ] || [ -f "$worktree/.git" ]; then
    return 0
  fi
  echo "proplane-prakrit-sync: adding worktree $worktree for $branch"
  mkdir -p "$(dirname "$worktree")"
  run_git "$GIT_ROOT" fetch origin "$branch" || true
  if run_git "$GIT_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    run_git "$GIT_ROOT" worktree add -B "$branch" "$worktree" "origin/$branch"
  else
    run_git "$GIT_ROOT" worktree add -B "$branch" "$worktree" "origin/prakrit"
  fi
}

sync_prakrit_integration() {
  local line branch worktree port
  line=$(fm_proplane_agent_integration_rows) || return 0
  IFS=$'\t' read -r branch worktree port <<<"$line"
  ensure_worktree "$branch" "$worktree"
  echo "== sync integration $branch @ $worktree =="
  run_git "$worktree" fetch origin prakrit "$branch" || return 1
  run_git "$worktree" checkout "$branch"
  if run_git "$worktree" merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null; then
    run_git "$worktree" merge --ff-only "origin/$branch" || run_git "$worktree" pull --ff-only origin "$branch" || true
  else
    if [ "$DRY_RUN" -eq 0 ]; then
      fm_proplane_assert_resettable "$worktree" "proplane-prakrit-sync" "$FORCE" || return 1
    fi
    run_git "$worktree" reset --hard "origin/$branch" || return 1
  fi
  if should_restart_branch "$branch" && [ "$DRY_RUN" -eq 0 ]; then
    "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$worktree" "$port" || true
  fi
}

sync_sandbox() {
  local branch=$1 worktree=$2 port=$3
  ensure_worktree "$branch" "$worktree"
  echo "== merge prakrit -> $branch @ $worktree (localhost:$port) =="

  # A sandbox branch may not exist on origin yet; fetching it must not sink the
  # prakrit fetch that the merge actually depends on.
  run_git "$worktree" fetch origin prakrit || return 1
  run_git "$worktree" fetch origin "$branch" 2>/dev/null || true
  run_git "$worktree" checkout "$branch"

  if run_git "$worktree" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    if run_git "$worktree" merge-base --is-ancestor HEAD "origin/$branch"; then
      run_git "$worktree" merge --ff-only "origin/$branch" || true
    fi
  fi

  if [ "$RESET_FROM_PRAKRIT" -eq 1 ]; then
    # Hard-reset to origin/prakrit is opt-in twice: the flag AND
    # FM_ALLOW_PRAKRIT_HARD_RESET=1. Promote paths used to pass the flag
    # unconditionally and wiped lanes ahead of prakrit (claude-3 5d02d838 /
    # 5dce1126). Default posture is merge-only.
    if [ "${FM_ALLOW_PRAKRIT_HARD_RESET:-}" != "1" ]; then
      echo "proplane-prakrit-sync: --reset-from-prakrit ignored (set FM_ALLOW_PRAKRIT_HARD_RESET=1 to allow hard-reset)" >&2
      echo "  merging origin/prakrit into $branch instead (never destroys unique commits)" >&2
      if run_git "$worktree" merge-base --is-ancestor "origin/prakrit" HEAD 2>/dev/null; then
        echo "proplane-prakrit-sync: $branch already contains origin/prakrit"
      elif ! run_git "$worktree" merge --no-edit "origin/prakrit" -m "chore(sync): prakrit into $branch"; then
        echo "proplane-prakrit-sync: BLOCKED merge conflict on $branch — resolve in $worktree" >&2
        return 1
      fi
    elif [ "$DRY_RUN" -eq 0 ]; then
      fm_proplane_assert_resettable "$worktree" "proplane-prakrit-sync" "$FORCE" || return 1
      # Even with the env gate, hard-reset only when this tip is already in
      # prakrit. --force only authorizes discarding a dirty working tree.
      if run_git "$worktree" merge-base --is-ancestor HEAD origin/prakrit 2>/dev/null; then
        echo "proplane-prakrit-sync: reset $branch to origin/prakrit (local tip already contained)"
        run_git "$worktree" reset --hard "origin/prakrit" || return 1
      else
        echo "proplane-prakrit-sync: SKIP reset $branch — HEAD has commits not in origin/prakrit" >&2
        echo "  refusing to destroy unique sandbox work; merging prakrit instead" >&2
        if ! run_git "$worktree" merge --no-edit "origin/prakrit" -m "chore(sync): prakrit into $branch"; then
          echo "proplane-prakrit-sync: BLOCKED merge conflict on $branch — resolve in $worktree" >&2
          return 1
        fi
      fi
    fi
  elif run_git "$worktree" merge-base --is-ancestor "origin/prakrit" HEAD 2>/dev/null; then
    echo "proplane-prakrit-sync: $branch already contains origin/prakrit"
  else
    if ! run_git "$worktree" merge --no-edit "origin/prakrit" -m "chore(sync): prakrit into $branch"; then
      echo "proplane-prakrit-sync: BLOCKED merge conflict on $branch — resolve in $worktree" >&2
      return 1
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$NO_PUSH" -eq 0 ]; then
      run_git "$worktree" push origin "$branch"
    fi
    "$SCRIPT_DIR/fm-proplane-write-agent-branch-rule.sh" "$branch" "$worktree" "$port"
    if should_restart_branch "$branch"; then
      "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$worktree" "$port" || true
    fi
  fi
  echo "proplane-prakrit-sync: ok $branch -> http://localhost:${port}"
}

main() {
  run_git "$GIT_ROOT" fetch origin prakrit || exit 1
  sync_prakrit_integration || true

  local failed=0
  while IFS=$'\t' read -r branch worktree port; do
    [ -n "$branch" ] || continue
    if [ -n "$ONLY_BRANCH" ] && [ "$branch" != "$ONLY_BRANCH" ]; then
      continue
    fi
    if ! sync_sandbox "$branch" "$worktree" "$port"; then
      failed=$((failed + 1))
    fi
  done < <(fm_proplane_agent_sandbox_rows)

  if [ "$failed" -gt 0 ]; then
    echo "proplane-prakrit-sync: $failed branch(es) failed" >&2
    exit 1
  fi
  echo "proplane-prakrit-sync: all agent branches synced from prakrit"
}

main
