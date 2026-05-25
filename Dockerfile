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
RUN curl -fsSL \
    "https://gitea.com/gitea/tea/releases/download/v0.14.1/tea-linux-amd64" \
    -o /usr/local/bin/tea \
    && chmod +x /usr/local/bin/tea

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

# Use login bash for all subsequent RUN layers so ~/.bashrc / profile is sourced
SHELL ["/bin/bash", "-lc"]

# ─── Layer 5: fnm (Fast Node Manager) ────────────────────────────────────────
ENV FNM_DIR="/home/agent/.local/share/fnm"
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
ENV PATH="${PNPM_HOME}:${PATH}"

RUN eval "$(fnm env --use-on-cd --shell bash)" \
    && curl -fsSL https://get.pnpm.io/install.sh | sh - \
    && echo 'export PNPM_HOME="/home/agent/.local/share/pnpm"' >> ~/.bashrc \
    && echo 'case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac' >> ~/.bashrc \
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

# ─── Layer 11: Clone skills (caveman + worktrunk) ────────────────────────────
# caveman  pinned @ ef6050c (2026-05-25)
# worktrunk pinned @ 58168f4 (2026-05-25)
USER root
RUN git clone https://github.com/JuliusBrussee/caveman.git /opt/skills/caveman \
    && git -C /opt/skills/caveman checkout ef6050c \
    && git clone https://github.com/max-sixty/worktrunk.git /opt/skills/worktrunk \
    && git -C /opt/skills/worktrunk checkout 58168f4

USER agent
RUN mkdir -p /home/agent/.claude/plugins/marketplaces \
    && ln -s /opt/skills/caveman  /home/agent/.claude/plugins/marketplaces/caveman \
    && ln -s /opt/skills/worktrunk /home/agent/.claude/plugins/marketplaces/worktrunk

# ─── Layer 12: Bake settings.json (caveman auto-activation + plugins) ─────────
COPY --chown=agent:agent docker/settings.json /home/agent/.claude/settings.json

# ─── Final configuration ─────────────────────────────────────────────────────
WORKDIR /home/agent/Repositories

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash"]
