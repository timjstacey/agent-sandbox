# agent-sandbox

A Dockerized Claude Code sandbox. Runs Claude Code and supporting dev tooling in an isolated container against your host repositories. The container holds the agent user; your host repos and credentials are bind-mounted at runtime. Claude Code gets full control over the mounted code while your host system stays protected — the AI agent never touches anything outside the mounts.

## Prerequisites

- Docker with the Compose plugin (`docker compose version` should work)
- A dedicated `agent` user created on the host
- POSIX ACLs configured on `~/Repositories` and relevant config files so the container's `agent` UID can read/write them
- SSH agent running on the host (`$SSH_AUTH_SOCK` set)

See [docs/host-setup.md](docs/host-setup.md) for the full one-time setup walkthrough.

## Quickstart

```bash
git clone gitea@git.sillysamoyed.com:tim/agent-sandbox.git
cd agent-sandbox

# Build — UID/GID must match the host agent user
export AGENT_UID=$(id -u agent) AGENT_GID=$(id -g agent)
docker compose build agent

# Run an interactive shell inside the container
./bin/agent-sandbox

# Or launch Claude Code directly
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
| `@anthropic-ai/claude-code` | `claude` on PATH; uses your host OAuth credentials |
| Playwright MCP | Sidecar container (`mcr.microsoft.com/playwright/mcp`), auto-started via Compose and registered as an MCP server |
| caveman skill | Baked in, auto-activated at session start to reduce token usage |
| worktrunk skill | Baked in for git worktree management inside the container |

## Learn more

- [docs/host-setup.md](docs/host-setup.md) — one-time host preparation (agent user, ACLs, SSH agent)
- [docs/plan.md](docs/plan.md) — architecture decisions and design context
- [CLAUDE.md](CLAUDE.md) — contributor guidance for Claude Code sessions working on this project
