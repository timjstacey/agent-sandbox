# syntax=docker/dockerfile:1
FROM debian:trixie-slim

# ─── Build args ──────────────────────────────────────────────────────────────
# Default to the conventional first-user UID/GID on Linux desktops. The wrapper
# script (bin/agent-sandbox build) overrides these with `id -u` / `id -g` of
# the invoking host user so that bind-mounted files land owned by that user.
ARG AGENT_UID=1000
ARG AGENT_GID=1000

# ─── Layer 1: System packages ────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssh-client \
    gnupg \
    jq \
    xz-utils \
    unzip \
    libatomic1 \
    acl \
    bash-completion \
    && rm -rf /var/lib/apt/lists/*

# ─── Layer 2: GitHub CLI (gh) via official apt repo ─────────────────────────
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ─── Layer 3: Gitea tea CLI (static binary) ──────────────────────────────────
ARG TEA_VERSION=0.14.1
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL \
       "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/tea-${TEA_VERSION}-linux-${arch}" \
       -o /usr/local/bin/tea \
    && chmod +x /usr/local/bin/tea \
    && tea --version

# ─── Layer 4: agent user ─────────────────────────────────────────────────────
# UID/GID match the host invoker so bind-mounted files appear owned by them on
# the host (no sudo needed to edit). Defensive: reuse any pre-existing group/
# user that already occupies the target UID/GID rather than failing the build.
RUN if ! getent group "${AGENT_GID}" >/dev/null; then \
        groupadd --gid "${AGENT_GID}" agent; \
    fi \
    && if ! getent passwd "${AGENT_UID}" >/dev/null; then \
        useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" \
                --create-home --home-dir /home/agent \
                --shell /bin/bash \
                --no-log-init \
                agent; \
    fi \
    && mkdir -p /home/agent/Repositories \
    && chown -R "${AGENT_UID}:${AGENT_GID}" /home/agent

# ─── Copy entrypoint (as root, before USER switch) ───────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

# ─── Switch to non-root agent user ───────────────────────────────────────────
USER agent
WORKDIR /home/agent

ENV SHELL=/bin/bash
# Default terminal type — claude (and most TUIs) refuse to draw without one,
# and `docker compose run` does not forward host TERM by default.
ENV TERM=xterm-256color
SHELL ["/bin/bash", "-c"]

# ─── Layer 5: fnm (Fast Node Manager) ────────────────────────────────────────
ENV FNM_DIR="/home/agent/.local/share/fnm"
ENV PATH="${FNM_DIR}:${PATH}"
RUN curl -fsSL https://fnm.vercel.app/install | bash \
    && echo 'eval "$(fnm env --use-on-cd --shell bash)"' >> ~/.bashrc

# ─── Layer 6: Node LTS (22) via fnm ─────────────────────────────────────────
# fnm installs Node into $FNM_DIR/node-versions/; the default alias symlink sits at
# $FNM_DIR/aliases/default → ../node-versions/<version>/installation
# We add that bin dir to PATH so subsequent RUN layers (and ENV at runtime) see node/npm.
RUN eval "$(fnm env --use-on-cd --shell bash)" \
    && fnm install --lts \
    && fnm alias default lts-latest \
    && fnm use default \
    && node -v && npm -v

ENV PATH="/home/agent/.local/share/fnm/aliases/default/bin:${PATH}"

# ─── Layer 7: pnpm ───────────────────────────────────────────────────────────
ENV PNPM_HOME="/home/agent/.local/share/pnpm"
ENV PATH="${PNPM_HOME}/bin:${PATH}"

RUN eval "$(fnm env --use-on-cd --shell bash)" \
    && curl -fsSL https://get.pnpm.io/install.sh | sh - \
    && pnpm -v

# ─── Layer 8: bun ────────────────────────────────────────────────────────────
ENV BUN_INSTALL="/home/agent/.bun"
ENV PATH="/home/agent/.bun/bin:${PATH}"

RUN curl -fsSL https://bun.sh/install | bash \
    && echo 'export BUN_INSTALL="/home/agent/.bun"' >> ~/.bashrc \
    && echo 'export PATH="/home/agent/.bun/bin:$PATH"' >> ~/.bashrc \
    && bun -v

# ─── Layer 9: TypeScript + Claude Code ───────────────────────────────────────
RUN eval "$(fnm env --use-on-cd --shell bash)" \
    && npm install -g typescript @anthropic-ai/claude-code \
    && tsc -v && claude --version

# ─── Layer 9b: bashrc function — inject --mcp-config from repo-mounted .claude/ ─
# Bind-mounted .claude/mcp-config.json carries container-only MCP servers so
# the committed file (not the image) is the source of truth. The function wraps
# the real claude binary in interactive shells; bin/agent-sandbox injects the
# flag directly when invoking claude as a subcommand (non-interactive path).
RUN printf '%s\n' \
    'claude() { command claude --mcp-config "$HOME/.claude/mcp-config.json" "$@"; }' \
    >> /home/agent/.bashrc

# ─── Final configuration ─────────────────────────────────────────────────────
WORKDIR /home/agent/Repositories

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash"]
