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
| Claude Code auth | Container-local: bind-mount repo-relative `./.claude/` and `./.claude.json` (gitignored). Separate session from host — first container run prompts `/login` once and persists. Avoids ACL drift caused by host claude rewriting its state files atomically |
| Container-only MCP | Committed `.claude/mcp-config.json` bind-mounted into container. Interactive shells pick it up via a bashrc `claude()` function; `./bin/agent-sandbox claude` injects `--mcp-config` directly (non-interactive path). No binary shim, no `/etc/claude/`. |
| Skills | Declared in committed `.claude/settings.json` via `extraKnownMarketplaces` + `enabledPlugins`; fetched from GitHub on first `claude` launch. No image baking — bumping = edit settings.json, delete plugin cache, no rebuild. |
| `tea` CLI | Gitea `tea` (https://gitea.com/gitea/tea), not tea.xyz |
| Container user | Non-root `agent` inside the image, UID/GID supplied via `--build-arg` to match the **host invoker** (`id -u`/`id -g`). No separate host `agent` account — bind-mounted files appear owned by the host user, removing the need for POSIX ACLs |
| Bind-mount layout | Mirror host paths (`-v ~/Repositories:/home/agent/Repositories`) for copy/paste-friendly paths |
| Git push creds | Forward host SSH agent socket (`$SSH_AUTH_SOCK`), never copy keys |
| Node | `fnm` baked in, default = latest LTS |
| pnpm + bun | Official upstream installers |
| Entrypoint | `bash` shell with `claude` on PATH; user invokes Claude Code manually |
| gh + tea auth | Bind-mount host `~/.config/gh` and `~/.config/tea` read-write. Host `gh` stores OAuth token in system keyring (not in `hosts.yml`), so `bin/agent-sandbox` runs `gh auth token` on the host and injects the result as `GH_TOKEN` env var — picked up automatically by in-container `gh`. Falls back silently (warning only) if host `gh` is absent or unauthenticated. |
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

- `AGENT_UID` / `AGENT_GID` build args — set to the host invoker's `id -u`/`id -g` by `bin/agent-sandbox build` so bind-mounted files appear owned by the host user. No separate host `agent` account is required.
- No POSIX ACLs needed — direct UID match supersedes the earlier ACL-based scheme. See `docs/host-setup.md` § 5 for the security trade-off.
- Mirrored bind-mount paths — `~/Repositories` on host maps to `/home/agent/Repositories` in container. Paths look identical apart from the home prefix; preserve this.
- Claude state bind-mount — repo-local `./.claude/` and `./.claude.json` are mounted rw into the container. `.claude/settings.json` and `.claude/mcp-config.json` are **committed**; runtime state (credentials, sessions, plugin cache) is gitignored. Session is independent of the host's Claude Code login — each clone/worktree has its own container session.
- SSH agent socket forwarding — `$SSH_AUTH_SOCK` is bind-mounted; container never holds its own SSH private keys.
- `GH_TOKEN` injection — `bin/agent-sandbox` calls `gh auth token` on the host to extract the OAuth token from the system keyring (where host `gh` stores it) and exports it as `GH_TOKEN`. Compose passes it into the agent container; `gh` inside the container picks it up automatically. If host `gh` is absent or unauthenticated, a warning is printed and the container still starts — `gh` inside will be unauthenticated. Token is never written to disk inside the container; each `docker compose run` invocation gets a fresh env copy.

## Skills are marketplace-installed (repo-side)

Caveman and worktrunk are declared in committed `.claude/settings.json` and fetched from GitHub on first `claude` launch inside the container. No image baking. Sources:

- `https://github.com/JuliusBrussee/caveman.git`
- `https://github.com/max-sixty/worktrunk.git`

Caveman's own plugin registers the `SessionStart` hook that activates caveman mode by default.

**Pinning trade-off:** First launch in a fresh clone fetches HEAD of each marketplace. To pin to a specific commit, run `claude plugin install caveman@<sha> worktrunk@<sha>` after the initial install and commit the resulting `installed_plugins.json` — but that file is currently gitignored (machine-managed). If pinning becomes important, promote it to tracked.

## Build & run commands

```bash
# One-time: initialise repo-local Claude login state
./bin/agent-sandbox setup

# Build agent image (UID/GID matched to host invoker — wrapper handles it)
./bin/agent-sandbox build

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
