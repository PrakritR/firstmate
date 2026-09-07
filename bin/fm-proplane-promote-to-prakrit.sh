#!/usr/bin/env bash
# Merge one agent sandbox branch into prakrit with security review + no-mistakes.
#
# Standing captain order: agents land only on their keeper branch. Promotion runs
# validation on an integrate/* branch before pushing prakrit, then opens localhost
# on the review route the agent recorded via npm run sandbox:open.
#
# Usage:
#   fm-proplane-promote-to-prakrit.sh <agent-branch>
#   fm-proplane-promote-to-prakrit.sh cursor-1 --path /portal/tasks
#   fm-proplane-promote-to-prakrit.sh cursor-2 --validate-only
#   fm-proplane-promote-to-prakrit.sh cursor-1 --dry-run
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"
# shellcheck source=bin/fm-proplane-no-mistakes-gate.sh
. "$SCRIPT_DIR/fm-proplane-no-mistakes-gate.sh"

DRY_RUN=0
FORCE=0
SKIP_GATES=0
SKIP_SECURITY_REVIEW=0
VALIDATE_ONLY=0
OPEN_BROWSER=1
AGENT_BRANCH=""
REVIEW_PATH=""
INTEGRATE_BRANCH=""

usage() {
  echo "usage: fm-proplane-promote-to-prakrit.sh <agent-branch> [options]" >&2
  echo "  --path </route>     Open prakrit localhost here after promote (default: read .proplane-review-path from agent worktree)" >&2
  echo "  --open-browser      Open browser after promote (default)" >&2
  echo "  --no-browser        Skip browser open" >&2
  echo "  --validate-only     Re-run gates on existing integrate branch" >&2
  echo "  --skip-gates        CAPTAIN-AUTHORIZED ONLY: skip security review + no-mistakes" >&2
  echo "  --skip-security-review  CAPTAIN-AUTHORIZED ONLY: skip security review only" >&2
  echo "  --dry-run" >&2
  echo "  --force             CAPTAIN-AUTHORIZED ONLY: discard uncommitted sandbox work on realign" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --skip-gates) SKIP_GATES=1; shift ;;
    --skip-security-review) SKIP_SECURITY_REVIEW=1; shift ;;
    --open-browser) OPEN_BROWSER=1; shift ;;
    --no-browser) OPEN_BROWSER=0; shift ;;
    --path)
      REVIEW_PATH=${2:?--path requires a route}
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [ -z "$AGENT_BRANCH" ]; then
        AGENT_BRANCH=$1
        shift
      else
        echo "unknown argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

[ -n "$AGENT_BRANCH" ] || {
  usage
  exit 2
}

if ! fm_proplane_agent_is_sandbox "$AGENT_BRANCH"; then
  echo "proplane-promote: $AGENT_BRANCH is not a sandbox keeper branch" >&2
  exit 2
fi

command -v no-mistakes >/dev/null 2>&1 || {
  echo "proplane-promote: no-mistakes CLI required" >&2
  exit 1
}

GIT_ROOT=$(fm_proplane_agent_git_root) || exit 1
line=$(fm_proplane_agent_integration_rows) || {
  echo "proplane-promote: missing prakrit row in config" >&2
  exit 1
}
IFS=$'\t' read -r prakrit_branch prakrit_worktree prakrit_port <<<"$line"

agent_line=$(fm_proplane_agent_row_for_branch "$AGENT_BRANCH") || {
  echo "proplane-promote: unknown agent branch $AGENT_BRANCH" >&2
  exit 1
}
IFS=$'\t' read -r _ agent_worktree agent_port <<<"$agent_line"

INTEGRATE_BRANCH="integrate/${AGENT_BRANCH}-to-prakrit"

if [ -z "$REVIEW_PATH" ] && [ -f "$agent_worktree/.proplane-review-path" ]; then
  REVIEW_PATH=$(tr -d '[:space:]' <"$agent_worktree/.proplane-review-path")
fi
case "$REVIEW_PATH" in
  "") ;;
  /*) ;;
  *) REVIEW_PATH="/$REVIEW_PATH" ;;
esac

run_git() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY git -C $*"
    return 0
  fi
  git -C "$@"
}

prepare_integrate_branch() {
  run_git "$GIT_ROOT" fetch origin "$AGENT_BRANCH" "$prakrit_branch" || return 1
  if run_git "$GIT_ROOT" show-ref --verify --quiet "refs/heads/$INTEGRATE_BRANCH"; then
    run_git "$GIT_ROOT" branch -D "$INTEGRATE_BRANCH" || true
  fi
  run_git "$GIT_ROOT" checkout -B "$INTEGRATE_BRANCH" "origin/$prakrit_branch" || return 1
  if run_git "$GIT_ROOT" merge-base --is-ancestor "origin/$AGENT_BRANCH" HEAD 2>/dev/null; then
    echo "proplane-promote: integrate branch already contains origin/$AGENT_BRANCH"
    return 0
  fi
  if ! run_git "$GIT_ROOT" merge --no-edit "origin/$AGENT_BRANCH" \
    -m "integrate($AGENT_BRANCH): promote sandbox to prakrit (validation branch)"; then
    echo "proplane-promote: BLOCKED merge conflict — resolve in $GIT_ROOT on $INTEGRATE_BRANCH" >&2
    return 1
  fi
}

run_security_review() {
  "$SCRIPT_DIR/fm-proplane-security-review.sh" "$GIT_ROOT" --base "origin/$prakrit_branch" --head "$INTEGRATE_BRANCH"
}

merge_integrate_into_prakrit() {
  local integrate_sha
  integrate_sha=$(git -C "$GIT_ROOT" rev-parse "$INTEGRATE_BRANCH")
  run_git "$prakrit_worktree" fetch origin "$AGENT_BRANCH" "$prakrit_branch" || return 1
  run_git "$prakrit_worktree" checkout "$prakrit_branch" || return 1
  if run_git "$prakrit_worktree" merge-base --is-ancestor "$integrate_sha" HEAD 2>/dev/null; then
    echo "proplane-promote: prakrit already at integrate tip"
  elif ! run_git "$prakrit_worktree" merge --ff-only "$integrate_sha" 2>/dev/null; then
    if ! run_git "$prakrit_worktree" merge --no-edit "$integrate_sha" \
      -m "merge($AGENT_BRANCH): integrate agent branch into prakrit"; then
      echo "proplane-promote: BLOCKED merge conflict — resolve in $prakrit_worktree" >&2
      return 1
    fi
  fi
  run_git "$prakrit_worktree" push origin "$prakrit_branch" || return 1
  run_git "$GIT_ROOT" branch -D "$INTEGRATE_BRANCH" 2>/dev/null || true
}

open_review_url() {
  local url="http://localhost:${prakrit_port}${REVIEW_PATH:-/}"
  if [ "$OPEN_BROWSER" -eq 0 ]; then
    echo "proplane-promote: review at $url"
    return 0
  fi
  "$SCRIPT_DIR/fm-open-url.sh" "$url" || true
  echo "proplane-promote: opened $url"
}

main() {
  echo "== promote $AGENT_BRANCH -> $prakrit_branch (security review + no-mistakes) =="

  if [ "$VALIDATE_ONLY" -eq 0 ]; then
    echo "== prepare $INTEGRATE_BRANCH =="
    prepare_integrate_branch || exit 1
  else
    run_git "$GIT_ROOT" checkout "$INTEGRATE_BRANCH" 2>/dev/null || {
      echo "proplane-promote: missing $INTEGRATE_BRANCH — run without --validate-only first" >&2
      exit 1
    }
  fi

  if [ "$SKIP_GATES" -eq 1 ] || [ "$SKIP_SECURITY_REVIEW" -eq 1 ]; then
    echo "== security review: SKIPPED (captain-authorized) =="
  else
    echo "== security review =="
    run_security_review || exit 1
  fi

  if [ "$SKIP_GATES" -eq 1 ]; then
    echo "== no-mistakes validation: SKIPPED by --skip-gates (captain-authorized) =="
  else
    local intent
    intent="Promote $AGENT_BRANCH sandbox work into prakrit integration after captain-approved gate. Validate review, tests, document, and lint before pushing origin/prakrit and opening localhost for captain feature test. No fm/* remote branches."
    fm_proplane_run_no_mistakes "$GIT_ROOT" "$INTEGRATE_BRANCH" "$intent" "$DRY_RUN" || {
      echo "proplane-promote: no-mistakes did not complete — drive gates with no-mistakes axi respond, then re-run --validate-only" >&2
      exit 1
    }
    if [ "$DRY_RUN" -eq 0 ]; then
      fm_proplane_assert_no_mistakes_completed "$GIT_ROOT" || {
        echo "proplane-promote: re-run with --validate-only after gates pass" >&2
        exit 1
      }
    fi
  fi

  if [ "$VALIDATE_ONLY" -eq 1 ]; then
    echo "proplane-promote: validation complete on $INTEGRATE_BRANCH"
    exit 0
  fi

  merge_integrate_into_prakrit || exit 1

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY fm-proplane-prune-stray-branches.sh"
    echo "DRY fm-prakrit-sync-agent-branches.sh --no-restart"
    exit 0
  fi

  "$SCRIPT_DIR/fm-proplane-prune-stray-branches.sh" || exit 1
  # Merge prakrit into sandboxes — never --reset-from-prakrit. Hard-reset wiped
  # lanes with unique commits (claude-3). Opt-in hard-reset requires the sync
  # script flag AND FM_ALLOW_PRAKRIT_HARD_RESET=1.
  sync_args=(--no-restart)
  [ "$FORCE" -eq 1 ] && sync_args+=(--force)
  "$SCRIPT_DIR/fm-prakrit-sync-agent-branches.sh" "${sync_args[@]}" || exit 1

  "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$prakrit_worktree" "$prakrit_port" || true
  "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$agent_worktree" "$agent_port" || true

  "$SCRIPT_DIR/fm-proplane-branch-e2e.sh" --smoke prakrit || {
    echo "proplane-promote: ladder smoke e2e failed on prakrit" >&2
    exit 1
  }
  "$SCRIPT_DIR/fm-proplane-branch-e2e.sh" --smoke "$AGENT_BRANCH" || {
    echo "proplane-promote: ladder smoke e2e failed on $AGENT_BRANCH" >&2
    exit 1
  }

  open_review_url

  echo "proplane-promote: ok $AGENT_BRANCH -> $prakrit_branch (http://localhost:${prakrit_port}${REVIEW_PATH:-/})"
  echo "proplane-promote: after captain tests prakrit, run fm-proplane-promote-prakrit-to-main.sh --push-main"
}

main
