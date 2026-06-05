#!/usr/bin/env bash
set -euo pipefail

: "${HOST_USER:?HOST_USER required}" "${HOST_UID:?HOST_UID required}" "${HOST_GID:?HOST_GID required}"

case "$HOST_USER" in
  root|daemon|bin|sys|nobody)
    echo "Refusing reserved username: $HOST_USER" >&2; exit 1 ;;
esac

# Group
if ! getent group "$HOST_GID" >/dev/null; then
  groupadd -g "$HOST_GID" "$HOST_USER"
fi

# User
if ! getent passwd "$HOST_UID" >/dev/null; then
  useradd -u "$HOST_UID" -g "$HOST_GID" -m -d "/home/$HOST_USER" \
          -s /bin/bash --no-log-init "$HOST_USER"
fi
RESOLVED_USER="$(getent passwd "$HOST_UID" | cut -d: -f1)"
HOME_DIR="$(getent passwd "$HOST_UID" | cut -d: -f6)"

# Seed skel once — useradd -m already copies /etc/skel (which may include a
# default .bashrc), so we overlay skel-agent on top and track with our own marker.
if [ ! -f "$HOME_DIR/.skel-agent-seeded" ]; then
  cp -aT /etc/skel-agent/ "$HOME_DIR/"
  mkdir -p "$HOME_DIR/.config/worktrunk"
  touch "$HOME_DIR/.skel-agent-seeded"
fi

# Ensure ownership — only recurse if the volume root is still root-owned (first run).
# Skipping on subsequent starts avoids a multi-second chown over the provisioned toolchain.
if [ "$(stat -c %u "$HOME_DIR")" != "$HOST_UID" ]; then
  chown -R "$HOST_UID:$HOST_GID" "$HOME_DIR"
fi

# First-run provisioning (skipped in CI via SKIP_PROVISION=1)
MARKER="$HOME_DIR/.agent-sandbox-provisioned"
if [ ! -f "$MARKER" ] && [ "${SKIP_PROVISION:-0}" != "1" ]; then
  echo "[entrypoint] first-run provisioning (Node ${PROVISION_NODE_VERSION:-22} + pnpm + bun + claude)..."
  # Use non-login bash so .bashrc is not sourced — fnm env in .bashrc would fail before
  # any Node version is installed. Pass HOME explicitly; fnm/wt are on /usr/local/bin.
  gosu "$RESOLVED_USER" env HOME="$HOME_DIR" bash -c "
    set -euo pipefail
    export FNM_DIR=\"\$HOME/.local/share/fnm\"
    mkdir -p \"\$FNM_DIR\"
    fnm install ${PROVISION_NODE_VERSION:-22}
    fnm alias default ${PROVISION_NODE_VERSION:-22}
    fnm use default
    eval \"\$(fnm env --shell bash)\"
    npm install -g pnpm typescript @anthropic-ai/claude-code
    curl -fsSL https://bun.sh/install | bash
    wt config shell install --yes bash
  "
  gosu "$RESOLVED_USER" touch "$MARKER"
fi

# Warn once per session if gh is not authenticated
if [ ! -s "$HOME_DIR/.config/gh/hosts.yml" ]; then
  echo "[entrypoint] gh not authenticated. Run 'gh auth login' inside the container; the token persists in the repo-local .config/gh." >&2
fi

exec gosu "$RESOLVED_USER" "$@"
