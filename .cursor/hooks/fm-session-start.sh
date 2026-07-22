#!/usr/bin/env bash
# Cursor sessionStart nudge: run firstmate session bootstrap once per open.
set -u

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd -P)"
[ -x "$ROOT/bin/fm-sessionstart-nudge.sh" ] || exit 0
exec "$ROOT/bin/fm-sessionstart-nudge.sh"
