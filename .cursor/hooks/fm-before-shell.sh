#!/usr/bin/env bash
# Cursor beforeShellExecution adapter for firstmate pretool seatbelts.
set -u

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd -P)"
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.command // empty' 2>/dev/null) || COMMAND=

allow() {
  printf '%s\n' '{ "permission": "allow" }'
}

if [ -z "$COMMAND" ]; then
  allow
  exit 0
fi

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-cursor-hook.XXXXXX")
trap 'rm -f "$ERR"' EXIT

for check in fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-continuity-pretool-check.sh; do
  if ! "$ROOT/bin/$check" --command "$COMMAND" 2>"$ERR"; then
    rc=$?
    if [ "$rc" -eq 2 ]; then
      msg=$(jq -r '.hookSpecificOutput.systemMessage // empty' <"$ERR" 2>/dev/null || true)
      [ -n "$msg" ] || msg=$(tr '\n' ' ' <"$ERR" | cut -c1-2000)
      jq -n --arg m "$msg" '{ "permission": "deny", "agent_message": $m }'
      exit 2
    fi
  fi
done

allow
exit 0
