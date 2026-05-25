# syntax=docker/dockerfile:1
FROM debian:trixie-slim

# ─── Build args ──────────────────────────────────────────────────────────────
ARG AGENT_UID=1500
ARG AGENT_GID=1500

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
RUN groupadd --gid "${AGENT_GID}" agent \
    && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" \
               --create-home --home-dir /home/agent \
               --shell /bin/bash \
               --no-log-init \
               agent \
    && mkdir -p /home/agent/Repositories \
    && chown -R agent:agent /home/agent

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

# ─── Layer 9b: claude shim — inject container-only MCP config ────────────────
# ~/.claude.json is bind-mounted rw from the host, so we must NOT write
# container-only MCP servers into it. Instead the shim invokes claude with
# --mcp-config pointing at an image-baked file. The npm-installed claude is
# renamed to claude.real; the shim takes its place on PATH.
USER root
RUN CLAUDE_BIN="$(command -v claude)" \
    && test -n "${CLAUDE_BIN}" \
    && mv "${CLAUDE_BIN}" "${CLAUDE_BIN}.real" \
    && printf '%s\n' \
       '#!/bin/bash' \
       'exec "$(dirname "$(readlink -f "$0")")/claude.real" --mcp-config /etc/claude/mcp-config.json "$@"' \
       > "${CLAUDE_BIN}" \
    && chmod +x "${CLAUDE_BIN}" \
    && chown agent:agent "${CLAUDE_BIN}" "${CLAUDE_BIN}.real" \
    && install -d -o agent -g agent /home/agent/.local/bin \
    && ln -s "${CLAUDE_BIN}" /home/agent/.local/bin/claude
USER agent

# Host ~/.claude.json (bind-mounted) records installMethod=native and expects
# the binary at ~/.local/bin/claude. Prepend that dir to PATH so the symlink
# above resolves first; the shim's readlink -f then jumps to claude.real in
# the fnm bin dir, finding claude.real alongside it.
ENV PATH="/home/agent/.local/bin:${PATH}"

# ─── Layer 10: Clone skills + symlinks (caveman + worktrunk) ─────────────────
# caveman  pinned @ ef6050c (2026-05-25)
# worktrunk pinned @ 58168f4 (2026-05-25)
USER root
RUN git clone --filter=blob:none --no-tags https://github.com/JuliusBrussee/caveman.git /opt/skills/caveman \
    && git -C /opt/skills/caveman checkout ef6050c \
    && git clone --filter=blob:none --no-tags https://github.com/max-sixty/worktrunk.git /opt/skills/worktrunk \
    && git -C /opt/skills/worktrunk checkout 58168f4 \
    && chmod -R a+rX /opt/skills \
    && mkdir -p /home/agent/.claude/plugins/marketplaces \
    && ln -s /opt/skills/caveman  /home/agent/.claude/plugins/marketplaces/caveman \
    && ln -s /opt/skills/worktrunk /home/agent/.claude/plugins/marketplaces/worktrunk \
    && chown -R agent:agent /home/agent/.claude

USER agent

# ─── Layer 11: Bake settings.json (caveman auto-activation + plugins) ─────────
COPY --chown=agent:agent docker/settings.json /home/agent/.claude/settings.json

# ─── Layer 12: Bake MCP server config (Playwright sidecar) ───────────────────
# Loaded by the claude shim via --mcp-config so container-only servers stay out
# of the host-shared ~/.claude.json. Path is fixed; the shim references it.
USER root
RUN mkdir -p /etc/claude
COPY docker/mcp-config.json /etc/claude/mcp-config.json
RUN chmod 0644 /etc/claude/mcp-config.json
USER agent

# ─── Final configuration ─────────────────────────────────────────────────────
WORKDIR /home/agent/Repositories

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash"]
