# syntax=docker/dockerfile:1
FROM debian:trixie-slim

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
    bash-completion \
    gosu \
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

# ─── Layer 2b: Seed known_hosts for git remotes ─────────────────────────────
# Container has no per-user ~/.ssh and no /etc/ssh/ssh_known_hosts by default,
# so the first `git push` / `gh pr create` over SSH fails with
# "Host key verification failed". Seed the public host keys for the remotes
# this project pushes to. Rebuild the image to pick up key rotations or to
# add new hosts.
RUN ssh-keyscan -t rsa,ecdsa,ed25519 \
        github.com \
        > /etc/ssh/ssh_known_hosts \
    && chmod 0644 /etc/ssh/ssh_known_hosts

# ─── Layer 3: worktrunk wt CLI (static musl binary) ─────────────────────────
ARG WT_VERSION=0.53.0
RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
       amd64) wt_arch="x86_64" ;; \
       arm64) wt_arch="aarch64" ;; \
       *) echo "Unsupported arch: ${arch}"; exit 1 ;; \
    esac \
    && curl -fsSL \
       "https://github.com/max-sixty/worktrunk/releases/download/v${WT_VERSION}/worktrunk-${wt_arch}-unknown-linux-musl.tar.xz" \
       -o /tmp/worktrunk.tar.xz \
    && mkdir -p /tmp/worktrunk-extract \
    && tar xf /tmp/worktrunk.tar.xz --strip-components 1 -C /tmp/worktrunk-extract \
    && mv /tmp/worktrunk-extract/wt /tmp/worktrunk-extract/git-wt /usr/local/bin/ \
    && chmod +x /usr/local/bin/wt /usr/local/bin/git-wt \
    && rm -rf /tmp/worktrunk* \
    && wt --version

# ─── Layer 4: fnm (static binary) ────────────────────────────────────────────
ARG FNM_VERSION=1.38.1
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
       amd64) fnm_zip="fnm-linux.zip" ;; \
       arm64) fnm_zip="fnm-arm64.zip" ;; \
       *) echo "Unsupported arch: $arch"; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/fnm.zip \
       "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/${fnm_zip}" \
    && unzip -p /tmp/fnm.zip fnm > /usr/local/bin/fnm \
    && chmod +x /usr/local/bin/fnm \
    && rm /tmp/fnm.zip \
    && fnm --version

# ─── Entrypoint + skel ───────────────────────────────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint
COPY docker/skel-agent /etc/skel-agent

# ─── Runtime provisioning config ─────────────────────────────────────────────
ARG NODE_VERSION=22
ENV PROVISION_NODE_VERSION=${NODE_VERSION}

ENV SHELL=/bin/bash
ENV TERM=xterm-256color
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash"]
