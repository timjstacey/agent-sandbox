#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Credentials: copy host-mounted OAuth credentials into agent home so token
# refreshes succeed inside the container (the agent-owned copy is writable).
# ---------------------------------------------------------------------------
# ~/.claude is bind-mounted directly from the host — credentials are shared
# and persist automatically. No copying needed.

# ---------------------------------------------------------------------------
# fnm: initialise Fast Node Manager so the default Node LTS is on PATH.
# ---------------------------------------------------------------------------
FNM_DIR="${FNM_DIR:-${HOME}/.local/share/fnm}"
export FNM_DIR
export PATH="${FNM_DIR}:${PATH}"
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi

# ---------------------------------------------------------------------------
# Hand off to the container command (default: bash via Dockerfile CMD).
# ---------------------------------------------------------------------------
exec "$@"
