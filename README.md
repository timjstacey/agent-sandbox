# agent-sandbox

A Dockerized Claude Code sandbox. Runs Claude Code and supporting dev tooling in an isolated container against your host repositories. The in-container `agent` user is built with your host UID/GID so files written to bind mounts land owned by you (no `sudo` to edit). Your host repos are bind-mounted at runtime; Claude Code gets full control over the mounted code while host paths outside the mounts remain unreachable from inside the container. The container has its own Claude Code login (persisted in a repo-local, gitignored directory), independent of your host's.

## Prerequisites

- Docker with the Compose plugin (`docker compose version` should work)
- SSH agent running on the host (`$SSH_AUTH_SOCK` set)
- `gh` and `tea` authenticated on the host (`gh auth login`, `tea login`) — their config dirs are bind-mounted into the container

See [docs/host-setup.md](docs/host-setup.md) for the full one-time setup walkthrough, including the security trade-off of UID-matching.

## Quickstart

```bash
git clone git@github.com:timjstacey/agent-sandbox.git
cd agent-sandbox

# One-time setup (initialise repo-local container Claude state)
./bin/agent-sandbox setup

# Build — wrapper passes the host invoker's UID/GID so files land owned by you
./bin/agent-sandbox build

# Run an interactive shell inside the container
./bin/agent-sandbox

# Or launch Claude Code directly (first run prompts /login once)
./bin/agent-sandbox claude
```

## What's inside the image

| Component | Details |
|---|---|
| Base | `debian:trixie-slim` |
| `gh` | GitHub CLI |
| `tea` | Gitea CLI |
| `fnm` + Node.js | fnm with Node.js LTS (v22) as default |
| `pnpm`, `bun` | Installed via their official upstream scripts |
| `typescript` | `tsc` available globally |
| `@anthropic-ai/claude-code` | `claude` on PATH; container has its own login persisted in `./.claude/` (gitignored) |
| Playwright MCP | Sidecar container (`mcr.microsoft.com/playwright/mcp`), auto-started via Compose and registered as an MCP server |
| caveman skill | Baked in, auto-activated at session start to reduce token usage |
| worktrunk skill | Baked in for git worktree management inside the container |

## Learn more

- [docs/host-setup.md](docs/host-setup.md) — one-time host preparation (UID matching, SSH agent, security trade-off)
- [docs/plan.md](docs/plan.md) — architecture decisions and design context
- [CLAUDE.md](CLAUDE.md) — contributor guidance for Claude Code sessions working on this project
