Mode: Cursor foreground-checkpoint supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run a bounded foreground checkpoint as its own call:

   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-checkpoint.sh --seconds 180`

4. Trust only the checkpoint's one-line reason output.
5. `signal:`, `stale:`, `check:`, or `heartbeat` in that output means an actionable wake arrived.
6. Failure or missing cycle only: repair with the same foreground checkpoint call.
7. After handling a wake, repeat the foreground checkpoint while work remains in flight or X mode still needs polling.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Project hooks in `.cursor/hooks.json` deny unsafe arm bundling and persistent `cd` into `projects/` before shell commands run.

Cursor does not yet have a verified tracked-background arm path like Claude or Grok.
Use the Codex-style foreground checkpoint until live evidence promotes a background adapter.
