#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Credentials: copy host-mounted OAuth credentials into agent home so token
# refreshes succeed inside the container (the agent-owned copy is writable).
# ---------------------------------------------------------------------------
HOST_CREDS="/tmp/host-credentials.json"
AGENT_CREDS_DIR="${HOME}/.claude"
AGENT_CREDS="${AGENT_CREDS_DIR}/.credentials.json"

if [ -f "${HOST_CREDS}" ]; then
    if [ ! -f "${AGENT_CREDS}" ] || ! cmp -s "${HOST_CREDS}" "${AGENT_CREDS}" 2>/dev/null; then
        mkdir -p "${AGENT_CREDS_DIR}"
        cp "${HOST_CREDS}" "${AGENT_CREDS}"
        chmod 600 "${AGENT_CREDS}"
    fi
fi

# ---------------------------------------------------------------------------
# fnm: initialise Fast Node Manager so the default Node LTS is on PATH.
# ---------------------------------------------------------------------------
FNM_DIR="${FNM_DIR:-${HOME}/.local/share/fnm}"
export FNM_DIR
export PATH="${FNM_DIR}:${PATH}"
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd)"
fi

# ---------------------------------------------------------------------------
# Hand off to the container command (default: bash via Dockerfile CMD).
# ---------------------------------------------------------------------------
exec "$@"
