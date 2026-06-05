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
| Container user | **Run-time-injected** via entrypoint from `HOST_USER`/`HOST_UID`/`HOST_GID` env (set by `bin/agent-sandbox`). No build args. Container starts as root (`user: "0:0"`); entrypoint creates matching user and drops via `gosu`. Bind-mounted files appear owned by the host user. |
| Bind-mount layout | Mirror host paths. The host projects dir is chosen at `setup` time (prompted, default `~/Repositories`) and written to gitignored `.env` as `PROJECTS_DIR` + `PROJECTS_BASENAME`; compose mounts `${PROJECTS_DIR}:/home/${HOST_USER}/${PROJECTS_BASENAME}` so container ↔ host paths match. Container `$HOME` = `/home/${HOST_USER}`, identical to host. |
| Git push creds | Forward host SSH agent socket (`$SSH_AUTH_SOCK`), never copy keys. Public host keys for git remotes (`github.com`) are baked into `/etc/ssh/ssh_known_hosts` at image build time — rebuild to rotate or add hosts. |
| Toolchain provisioning | `fnm`, `gh`, `wt`, `gosu` baked into image (static binaries / apt). Node + pnpm + bun + claude + typescript provisioned per-user on **first container run** into named volume `agent-home`. Marker file `~/.agent-sandbox-provisioned` gates re-runs. |
| gh auth | Host login preferred — gh stores in keyring, `bin/agent-sandbox` injects `GH_TOKEN` env. Host-not-logged-in is non-fatal: wrapper creates empty `~/.config/gh` dir, container can run `gh auth login` inline (plaintext, persisted via bind mount). |
| Git identity | Bind-mount host `~/.gitconfig` read-only |
| Distribution UX | Host wrapper script `bin/agent-sandbox` wrapping `docker compose run` |

## Why the container runs as the host UID

The "Container user" decision above describes the *mechanism* (runtime-injected user, drop via `gosu`). This section is the *why* — captured so the decision isn't silently re-litigated. The decision is **keep UID-matching**.

**Rationale.** The whole point of this container is an agent that edits your real repos in place via a bind mount. Running as the host UID/GID is the simplest correct ownership model for that: files the container writes into `Repositories` land owned by the host user — no `sudo`, no ACL drift, ownership "just works" bidirectionally.

**Trade-off (inherent, not incidental).** Running as your UID means a container escape acts as your UID **over the mounted surface only** — it does *not* grant root. Docker namespace isolation and SSH-agent socket forwarding (no private keys ever enter the container) still hold. For a dev sandbox this is the accepted boundary; see [`docs/host-setup.md`](docs/host-setup.md) §9.

**Mounted surface (everything visible inside the container — nothing else from the host):**

- the projects dir (`PROJECTS_DIR`, default `~/Repositories`);
- repo-local Claude state — `./.claude/` and `./.claude.json`;
- the repo-local gh config dir;
- the worktrunk config (`./docker/wt-config.toml`);
- the host `~/.gitconfig`, mounted **read-only**;
- the forwarded SSH agent socket (`$SSH_AUTH_SOCK`).

**Alternatives considered & rejected:**

- *POSIX ACLs* (`setfacl`, the original `plan.md` approach) — fragile and drift-prone; already abandoned.
- *Rootless Docker / userns-remap* — cleaner isolation on paper, but bind-mount ownership gets remapped through the subuid range, reintroducing exactly the ownership-mismatch pain UID-matching avoids (plus more host setup).
- *Podman `--userns=keep-id`* — functionally equivalent to what we do, just built in. A viable future port, **not** a security improvement.
- *Named-volume-only (no repo bind mount)* — defeats the purpose (the agent must edit your real repos).

## Repository topology

- This repo lives at `~/Repositories/agent-sandbox` on the maintainer's host as a **bare** repository (`.git/` inside a wrapper dir). There is no working tree at the bare-repo root — never edit there.
- Remote: `git@github.com:timjstacey/agent-sandbox.git` (GitHub).
- Worktrees are managed by [worktrunk](https://github.com/max-sixty/worktrunk). Create one with `wt switch <branch>` (or `wt switch -c <new-branch>`) before editing.
- Default worktree path for this repo is `~/Repositories/agent-sandbox/.git.<branch>` — not a typo, that's how `wt` names worktrees of a bare repo without a per-project `worktree-path` template.

## Workflow conventions

- **One feature per branch / worktree.** Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`. This is a bare/worktrunk repo: never start work with `git checkout -b` or `git branch` — always `wt switch -c <branch>` (or `wt switch <branch>` for an existing branch).
- **Issues drive work.** Each scoped task is a GitHub issue against `timjstacey/agent-sandbox` (created via `gh issue create`). When implementing, open a PR with `gh pr create` and reference the issue.
- **Scope discipline.** Don't expand beyond what the issue asks. Cross-file refactors require their own issue.
- **Commit messages.** Conventional Commits style; the worktrunk LLM commit generator is configured globally.

## Host coupling points

These exist because the container exists to bridge an isolated env to the host. Don't strip them without understanding the consequence:

- `HOST_USER`/`HOST_UID`/`HOST_GID` env passthrough — set by `bin/agent-sandbox` from `id -un`/`id -u`/`id -g`, consumed by entrypoint to create matching user at run time. No build args, no separate host account.
- `COMPOSE_PROJECT_NAME=agent-sandbox-${HOST_USER}` — isolates named volumes per host user on shared Docker daemons.
- Mirrored bind-mount paths — the host projects dir (`PROJECTS_DIR` from `.env`, default `~/Repositories`) maps to `/home/${HOST_USER}/${PROJECTS_BASENAME}` in container. Paths look identical; preserve this.
- Claude state bind-mount — repo-local `./.claude/` and `./.claude.json` are mounted rw into the container. `.claude/settings.json` and `.claude/mcp-config.json` are **committed**; runtime state (credentials, sessions, plugin cache) is gitignored. Session is independent of the host's Claude Code login — each clone/worktree has its own container session. Committed `settings.json` also carries a `permissions.deny` list (blocks the agent from reading `.env*`, `*.pem`, `*.key`, `.ssh/**`, `.aws/**`, secrets/credentials dirs, compose files) plus `defaultMode: auto`, `effortLevel: high`, and `skipAutoPermissionPrompt`.
- Worktrunk config bind-mount — `./docker/wt-config.toml` is mounted read-write at `~/.config/worktrunk/config.toml` so in-container `wt` shares the project's worktrunk config.
- SSH agent socket forwarding — `$SSH_AUTH_SOCK` is bind-mounted; container never holds its own SSH private keys.
- `GH_TOKEN` injection — `bin/agent-sandbox` calls `gh auth token` on the host to extract the OAuth token from the system keyring (where host `gh` stores it) and exports it as `GH_TOKEN`. Compose passes it into the agent container; `gh` inside the container picks it up automatically. If host `gh` is absent or unauthenticated, a warning is printed and the container still starts — `gh` inside will be unauthenticated. Token is never written to disk inside the container; each `docker compose run` invocation gets a fresh env copy.

## Skills are marketplace-installed (repo-side)

Caveman and worktrunk are declared in committed `.claude/settings.json` and fetched from GitHub on first `claude` launch inside the container. No image baking. Sources:

- `https://github.com/JuliusBrussee/caveman.git`
- `https://github.com/max-sixty/worktrunk.git`

Caveman's own plugin registers the `SessionStart` hook that activates caveman mode by default.

`./bin/agent-sandbox setup` pre-fetches both plugins (tarball of each repo's `main` branch) into the gitignored `.claude/plugins/cache/` so the caveman `SessionStart` hook fires on the first `claude` launch. If `setup` is skipped (or the cache is deleted), `claude` fetches HEAD of each marketplace on first launch instead.

**Pinning trade-off:** Both paths track `main`/HEAD, not a pinned commit. To pin, run `claude plugin install caveman@<sha> worktrunk@<sha>` after the initial install and commit the resulting `installed_plugins.json` — but that file is currently gitignored (machine-managed). If pinning becomes important, promote it to tracked.

## CI

Two GitHub Actions workflows under `.github/workflows/`:

- **`pr.yml`** (on PR to `main`) — `lint` job runs actionlint, hadolint (`Dockerfile`, ignoring `DL3008`), and `docker compose config --quiet`. `build-and-test` job builds the image (`load`, no push) and runs three smoke tests under `SKIP_PROVISION=1`: static tool versions (`fnm`/`gh`/`wt`/`git`), user/UID identity match, and the bashrc `claude()` `--mcp-config` shim.
- **`build.yml`** (on push to `main`, `v*` tags, manual) — builds `linux/amd64` and pushes to GHCR `ghcr.io/timjstacey/agent-sandbox` with `latest` / semver / `sha-` tags. Uses a registry build cache (`:buildcache`).

`SKIP_PROVISION=1` (consumed by `docker/entrypoint.sh`) skips first-run per-user provisioning so CI tests only the baked-in static layers.

## Build & run commands

```bash
# One-time: prompt for projects dir → write .env, pre-create .claude.json,
# and pre-install caveman + worktrunk plugins into .claude/plugins/cache/
# (so the caveman SessionStart hook fires on the first claude launch, not the second)
./bin/agent-sandbox setup

# Sanity-check setup (claude state, settings.json, plugins, gitconfig, repos writable)
./bin/agent-sandbox verify

# Build agent image (portable — no UID baking)
./bin/agent-sandbox build

# Full stack (agent + playwright-mcp sidecar)
docker compose up -d playwright-mcp
./bin/agent-sandbox                       # drops into bash inside container
./bin/agent-sandbox claude                # launches Claude Code directly

# AGENT_WORKDIR=<path> sets the container working directory for either invocation.
```

## Open items

Resolved since `docs/plan.md` was written:

- **Playwright MCP transport** — SSE over the internal network; sidecar runs `--host 0.0.0.0 --port 8931`, agent connects at `http://playwright-mcp:8931/sse` (see `.claude/mcp-config.json`). Image tag still `:latest` — compose carries a TODO to pin a digest before production.
- **CI image registry** — GHCR (`ghcr.io/timjstacey/agent-sandbox`), wired up in `.github/workflows/build.yml`.
- **`build-essential`** — not needed; `@anthropic-ai/claude-code` provisions via `npm i -g` at first run with no native build step.

Still open (see `docs/plan.md` → "Open items to confirm during implementation"):

- Pin the Playwright MCP image to an immutable tag/digest.
- Outbound network policy (default: unrestricted).
