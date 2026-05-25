# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

Dockerized, sandboxed Claude Code environment. Users bind-mount their repositories into the container at runtime and give the contained agent full control over those mounts without risking the host. The image stays lean — no full-OS bloat — and reuses the user's existing Claude Pro subscription (no API-key billing).

The full design rationale and decisions live in [`docs/plan.md`](docs/plan.md). Read it before making non-trivial changes.

## Locked-in design decisions

Do not re-litigate these without explicit user direction:

| Area | Choice |
|---|---|
| Base image | `debian:trixie-slim` |
| Playwright MCP | Sidecar container (`mcr.microsoft.com/playwright/mcp`), connected over the compose network |
| Claude Code auth | Bind-mount host `~/.claude/` and `~/.claude.json` rw so credentials + session state (oauthAccount, userID) are shared; one login on the host covers the container |
| Container-only MCP | Loaded via `claude --mcp-config /etc/claude/mcp-config.json` injected by a shim at `$(which claude)`, so the bind-mounted `~/.claude.json` is not polluted with container-only server entries |
| Skills | Baked at build via pinned `git clone` (caveman + worktrunk); caveman auto-activates at session start to cut token usage |
| `tea` CLI | Gitea `tea` (https://gitea.com/gitea/tea), not tea.xyz |
| Container user | Non-root `agent`, UID/GID supplied via `--build-arg` to match a dedicated `agent` user on the host |
| Bind-mount layout | Mirror host paths (`-v ~/Repositories:/home/agent/Repositories`) for copy/paste-friendly paths |
| Git push creds | Forward host SSH agent socket (`$SSH_AUTH_SOCK`), never copy keys |
| Node | `fnm` baked in, default = latest LTS |
| pnpm + bun | Official upstream installers |
| Entrypoint | `bash` shell with `claude` on PATH; user invokes Claude Code manually |
| gh + tea auth | Bind-mount host `~/.config/gh` and `~/.config/tea` read-write |
| Git identity | Bind-mount host `~/.gitconfig` read-only |
| Distribution UX | Host wrapper script `bin/agent-sandbox` wrapping `docker compose run` |

## Repository topology

- This repo lives at `~/Repositories/agent-sandbox` on the maintainer's host as a **bare** repository (`.git/` inside a wrapper dir). There is no working tree at the bare-repo root — never edit there.
- Remote: `git@github.com:timjstacey/agent-sandbox.git` (GitHub). The plan originally targeted self-hosted Gitea; the live remote is GitHub.
- Worktrees are managed by [worktrunk](https://github.com/max-sixty/worktrunk). Create one with `wt switch <branch>` (or `wt switch -c <new-branch>`) before editing.
- Default worktree path for this repo is `~/Repositories/agent-sandbox/.git.<branch>` — not a typo, that's how `wt` names worktrees of a bare repo without a per-project `worktree-path` template.

## Workflow conventions

- **One feature per branch / worktree.** Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`.
- **Issues drive work.** Each scoped task is a GitHub issue against `timjstacey/agent-sandbox` (created via `gh issue create`). When implementing, open a PR with `gh pr create` and reference the issue.
- **Scope discipline.** Don't expand beyond what the issue asks. Cross-file refactors require their own issue.
- **Commit messages.** Conventional Commits style; the worktrunk LLM commit generator is configured globally.

## Host coupling points

These exist because the container exists to bridge an isolated env to the host. Don't strip them without understanding the consequence:

- `AGENT_UID` / `AGENT_GID` build args — must match the host `agent` user so bind-mounted files have correct ownership.
- POSIX ACLs on host `~/Repositories`, `~/.claude`, `~/.claude.json`, `~/.gitconfig`, `~/.config/gh`, `~/.config/tea` — grant `agent` user rwx without changing primary ownership. Documented in `docs/host-setup.md`.
- Mirrored bind-mount paths — `~/Repositories` on host maps to `/home/agent/Repositories` in container. Paths look identical apart from the home prefix; preserve this.
- Claude state bind-mount — host `~/.claude/` and `~/.claude.json` are mounted rw. OAuth tokens and account state are shared bidirectionally, so one host login covers the container and refreshes propagate back.
- SSH agent socket forwarding — `$SSH_AUTH_SOCK` is bind-mounted; container never holds its own SSH private keys.

## Skills are baked, pinned

Caveman and worktrunk are cloned at image build from upstream GitHub at a pinned commit. Bumping requires a Dockerfile change + image rebuild. Sources:

- `https://github.com/JuliusBrussee/caveman.git`
- `https://github.com/max-sixty/worktrunk.git`

A `SessionStart` hook in the baked `~/.claude/settings.json` activates caveman by default in every fresh `claude` session to reduce token usage.

## Build & run commands

The wrapper script and compose file do not exist yet — they are tracked by Phase B issues. Once they land:

```bash
# Build agent image (UID/GID matching host agent user)
docker compose build --build-arg AGENT_UID=$(id -u agent) --build-arg AGENT_GID=$(id -g agent) agent

# Full stack (agent + playwright-mcp sidecar)
docker compose up -d playwright-mcp
./bin/agent-sandbox                       # drops into bash inside container
./bin/agent-sandbox claude                # launches Claude Code directly
```

## Open items tracked separately

See `docs/plan.md` → "Open items to confirm during implementation":

- Exact Playwright MCP image tag and transport (SSE port vs stdio)
- Whether `@anthropic-ai/claude-code` needs `build-essential` for native deps
- Outbound network policy (default: unrestricted)
- CI image registry (GHCR vs Docker Hub vs self-hosted Gitea registry) — blocks the CI workflow issue
