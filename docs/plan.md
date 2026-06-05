# Plan: Dockerized AI Agent Sandbox

## Context

User wants a reproducible, isolated environment to run Claude Code (and supporting dev tooling) against arbitrary host repositories, with the container holding "full control" over bind-mounted code while the host stays protected. Repo is currently empty — we are bootstrapping from zero. Output of the work this plan covers: a `CLAUDE.md` that guides future Claude Code sessions building this project, plus the initial repo scaffolding so the dockerization work can proceed.

Goals:
- Lean image (no full-OS bloat)
- Reuse user's existing Claude Pro subscription (no API key billing)
- Host isolation via Docker namespacing + narrow bind mounts (originally also via a dedicated host `agent` user — superseded by UID match; see decisions table)
- Reproducible, hermetic builds
- Smooth UX: one wrapper script to run

## Decisions (locked in via clarifications)

| Area | Choice |
|---|---|
| Base image | `debian:trixie-slim` |
| Playwright MCP | Sidecar container (Microsoft's `mcr.microsoft.com/playwright/mcp` or equivalent), connected over compose network |
| Claude Code auth | Container-local: bind-mount repo-relative `./.claude/` and `./.claude.json` (gitignored). Separate session from host login (first run does `/login` once and persists). Earlier designs shared host `~/.claude*` directly; abandoned because host claude rewrites those files atomically and strips the agent's POSIX ACL |
| Skills delivery | Baked at build via `git clone` (pinned commits); caveman skill auto-activated at session start to reduce token usage |
| Container user | Non-root `agent` inside the image, UID/GID via `--build-arg` matching the **host invoker** (`id -u`/`id -g`). No separate host `agent` account, no POSIX ACLs. (Superseded the earlier dedicated-host-user + ACL scheme — see § "Host one-time setup" amendment below) |
| Bind mount layout | Mirror host paths (`-v ~/Repositories:/home/agent/Repositories`) |
| Git push creds | Forward host SSH agent socket (`$SSH_AUTH_SOCK`) |
| Node | fnm baked in, default = latest LTS (Node 22 at time of writing) |
| pnpm + bun | Official upstream installers |
| Entrypoint | `bash` shell, `claude` on PATH; user invokes interactively |
| gh auth | Bind mount host `~/.config/gh` (read-write) |
| Git identity | Bind mount host `~/.gitconfig` read-only |
| Distribution UX | Host wrapper script (`agent-sandbox`) wrapping `docker compose run` |
| Skill repo sources | `https://github.com/JuliusBrussee/caveman.git`, `https://github.com/max-sixty/worktrunk.git` |

## Repo layout to create

```
agent-sandbox/
├── CLAUDE.md                       # Guidance for Claude Code working on THIS project
├── README.md                       # Human-facing setup + run docs
├── docs/
│   ├── plan.md                     # This planning doc, committed for issue references
│   └── host-setup.md               # ACLs, agent user creation, one-time host prep
├── Dockerfile                      # Agent image
├── compose.yml                     # agent + playwright-mcp services
├── .dockerignore
├── bin/
│   └── agent-sandbox               # Host wrapper script (bash)
├── docker/
│   ├── entrypoint.sh               # Copies credentials, sets up env, exec bash
│   ├── mcp-config.json             # Claude Code MCP server config (Playwright sidecar)
│   └── motd                        # First-run shell banner (optional)
└── .github/
    └── workflows/
        └── build.yml               # CI: build + push image on tag/main (GitHub Actions)
```

## Dockerfile outline

Single-stage, `debian:trixie-slim` base. Multi-stage only if image size becomes a concern; defer.

Build args: `AGENT_UID`, `AGENT_GID` (defaults 1500/1500).

Layers (ordered for cache stability — slow-changing first):
1. `apt-get install`: `ca-certificates curl git openssh-client gnupg jq xz-utils acl bash-completion` (and any libs `gh` needs)
2. Install `gh` from official apt repo or static release tarball
3. Create `agent` user with passed UID/GID, `/home/agent` home, bash shell
5. Switch to `USER agent`
6. Install fnm (`curl -fsSL https://fnm.vercel.app/install | bash`)
7. Use fnm to install latest LTS and set default; add fnm init to `~/.bashrc`
8. Install pnpm (`curl -fsSL https://get.pnpm.io/install.sh | sh -`)
9. Install bun (`curl -fsSL https://bun.sh/install | bash`)
10. `npm install -g typescript @anthropic-ai/claude-code` (via fnm-managed Node)
11. `git clone --depth 1 https://github.com/JuliusBrussee/caveman.git /opt/skills/caveman` and same for `worktrunk` — pin to specific tag/commit; symlink into `/home/agent/.claude/plugins/marketplaces/` (matching host layout discovered in `/home/tim/.claude/plugins/marketplaces/`)
12. Bake a `SessionStart` hook into `/home/agent/.claude/settings.json` that activates caveman mode by default (matches mechanism used by host `caveman` plugin — confirm exact hook command from cloned `caveman` repo before wiring). Goal: every fresh `claude` session in the container starts in caveman mode for token savings, unless user disables.
12. Copy `docker/entrypoint.sh` to `/usr/local/bin/entrypoint`, `chmod +x`
13. `ENTRYPOINT ["/usr/local/bin/entrypoint"]`, `CMD ["bash"]`
14. `WORKDIR /home/agent/Repositories`

## compose.yml outline

Two services on shared internal network:

- `agent`:
  - Built from `./Dockerfile`
  - `user: agent`
  - Volumes:
    - `${HOME}/Repositories:/home/agent/Repositories` (rw)
    - `./.claude:/home/agent/.claude` (rw, repo-local, gitignored)
    - `./.claude.json:/home/agent/.claude.json` (rw, repo-local, gitignored)
    - `${HOME}/.gitconfig:/home/agent/.gitconfig:ro`
    - `${HOME}/.config/gh:/home/agent/.config/gh:rw`
    - `${SSH_AUTH_SOCK}:/ssh-agent` + `SSH_AUTH_SOCK=/ssh-agent`
  - `tty: true`, `stdin_open: true`
  - `depends_on: [playwright-mcp]` (optional; agent works without it)
- `playwright-mcp`:
  - `image: mcr.microsoft.com/playwright/mcp:latest` (verify exact tag at build time)
  - Headless, exposes SSE/HTTP port on internal network only
  - No host bind mounts needed

Agent's MCP config points at `http://playwright-mcp:<port>/sse` (port confirmed when wiring).

## Host wrapper script (`bin/agent-sandbox`)

Bash script that:
1. Verifies host prerequisites (agent user exists, ACLs set on `~/Repositories`, `SSH_AUTH_SOCK` set, repo-local `./.claude/` + `./.claude.json` initialised)
2. Exports vars compose.yml expects
3. Runs `docker compose -f /path/to/compose.yml run --rm agent "$@"`

Argument-less invocation = interactive shell. With args = exec command.

## Host one-time setup (`docs/host-setup.md`)

**Amended — current scheme (UID match, no host `agent` user):**

- No dedicated host user. The in-image `agent` is created with UID/GID matching the host invoker, so bind-mounted files appear owned by the host user.
- `bin/agent-sandbox build` automatically passes `--build-arg AGENT_UID=$(id -u) AGENT_GID=$(id -g)`.
- `bin/agent-sandbox setup` initialises the repo-local container Claude state (`./.claude/` + `./.claude.json`) as the host user. No `sudo`, no ACLs.
- See `docs/host-setup.md` § 5 for the security trade-off (loss of UID-based home isolation; mitigations: narrow bind mounts, optional `userns-remap`).

**Historical (superseded) — original scheme used a dedicated host `agent` user plus POSIX ACLs:**

- Create `agent` user: `sudo useradd -r -m -s /usr/sbin/nologin agent`; lock with `sudo usermod -L agent`
- `setfacl -R -m u:agent:rwX ~/Repositories` (and default ACL); `setfacl -m u:agent:r ~/.gitconfig`; ACLs on `~/.config/gh`
- Pass `id -u agent`/`id -g agent` as build args

The ACL scheme worked but added constant `sudo`-to-edit friction (files in `~/Repositories` were owned by `agent:agent`) and suffered ACL drift whenever host tools rewrote files atomically. UID match trades the privilege barrier between container UID and host home for ergonomics; documented as a deliberate trade-off, not a regression.

## Entrypoint script (`docker/entrypoint.sh`)

- Set `FNM_DIR`, source fnm init
- `exec "$@"` (defaults to bash)

Note: container's Claude session is fully independent of the host's. Refreshes and `/login` events on either side do not propagate. Each clone/worktree has its own container session persisted in `./.claude/`.

## CLAUDE.md content (project-level, NOT bundled into image)

Sections to include:
- **Repository purpose**: dockerized agent sandbox, lean image, host isolation goals
- **Key decisions reference**: link/inline the decisions table above so future Claude doesn't re-litigate
- **Build commands**:
  - `docker compose build agent`
  - `./bin/agent-sandbox` to run
  - `docker compose run --rm agent claude` to launch Claude directly
- **Architecture notes**: two-container compose (agent + playwright-mcp sidecar), why sidecar over baked-in
- **Host coupling points** (so future edits don't break them): UID build arg, ACLs, bind mount paths, repo-local Claude state dir
- **Skills are baked, pinned** — bumping requires Dockerfile change + rebuild
- **Caveman/worktrunk source repos** with pinned commits
- Avoid generic dev advice per init instructions

## CI pipeline (`.github/workflows/build.yml`)

Build + push image on push to `main` and on tags. Registry TBD — placeholder for now, finalize before merging the workflow.

Sketch:
- Trigger: `push` to `main`, `push` of `v*` tag, `workflow_dispatch`
- Job uses `docker/setup-buildx-action` + `docker/build-push-action`
- Multi-platform: `linux/amd64` only initially (add `linux/arm64` later if needed)
- Tagging strategy via `docker/metadata-action`:
  - `latest` on default-branch push
  - `<semver>` and `<major>.<minor>` on tag push
  - `sha-<short>` always
- Build args: pass a default `AGENT_UID`/`AGENT_GID` (e.g., 1500); end users still rebuild locally with their own UID if required
- Login step: registry-specific secrets (`REGISTRY_USER` / `REGISTRY_TOKEN` or GHCR `GITHUB_TOKEN`)
- Cache: GHA registry cache via buildx

**Registry options (decide before wiring login step):**

| Registry | Pros | Cons |
|---|---|---|
| GHCR (`ghcr.io/<user>/agent-sandbox`) | Free for public, integrates with GitHub Actions via built-in `GITHUB_TOKEN`, no extra signup | Tied to GitHub account |
| Docker Hub | Most familiar, default for `docker pull` | Rate limits on free tier, extra account setup |
| Self-hosted (a private container registry, etc.) | Full control, matches a "self-hosted ethos" | Requires running a registry |

Recommendation when ready to decide: **GHCR** for simplicity unless self-hosting is desired.

## Repository topology

- `/home/tim/Repositories/agent-sandbox` is a **bare** repository (no working tree).
- Remote `origin` = `git@github.com:timjstacey/agent-sandbox.git` (GitHub).
- Work happens in worktrees managed by `wt` (worktrunk). Never edit inside the bare repo dir directly.
- A stray `CLAUDE.md` currently sits in the bare-repo root (untracked, created by `/init` before the bare nature was known). Delete it as part of cleanup.

## Implementation order

### Phase A — Bootstrap on `main` (this session)

1. `wt switch main` to materialize a worktree for `main`.
2. Delete stray `CLAUDE.md` from the bare-repo root: `rm /home/tim/Repositories/agent-sandbox/CLAUDE.md`.
3. Inside the worktree, write a proper `CLAUDE.md` (see "CLAUDE.md content" section) reflecting the full plan.
4. Copy this plan file into the repo as `docs/plan.md` (rename from `fancy-orbiting-dove.md` to something meaningful) so it lives with the codebase and Phase-B issues can link to it on GitHub.
5. Commit on `main` in one commit: `feat: bootstrap project guidance and implementation plan` — includes `CLAUDE.md` + `docs/plan.md`.
6. Push: `git push origin main`.

### Phase B — Issue split (GitHub, via `gh`)

Split the remaining work into small, independently-implementable GitHub issues so Claude Sonnet 4.6 can pick one off at a time and work in parallel worktrees. Each issue references this plan file and names the exact files to create. Suggested issues:

| # | Title | Scope |
|---|---|---|
| 1 | Add `Dockerfile` for agent image | `Dockerfile` + `.dockerignore`; build only, no compose yet |
| 2 | Add `docker/entrypoint.sh` | Credentials copy, fnm init, exec CMD |
| 3 | Add `docker/mcp-config.json` for Playwright sidecar | Claude Code MCP server entry |
| 4 | Add `compose.yml` with agent + playwright-mcp services | Two-service compose, bind mounts, SSH agent forward |
| 5 | Add `bin/agent-sandbox` host wrapper script | Bash wrapper around `docker compose run` |
| 6 | Add `docs/host-setup.md` | ACLs, agent user creation, one-time host prep |
| 7 | Add `README.md` quickstart | Public-facing setup + run docs |
| 8 | Bake caveman + worktrunk skills into image | Dockerfile clone steps + SessionStart hook for caveman auto-activation |
| 9 | Add `.github/workflows/build.yml` | CI build + push; registry TBD — block on registry decision |

Each issue body includes:
- Link to `fancy-orbiting-dove.md` plan (paste relevant section)
- Acceptance criteria from the Verification section
- Files to create/modify
- Branch naming convention (e.g., `feat/dockerfile`, `feat/compose`)

Create via `gh issue create --title "..." --body "$(cat <<'EOF' ... EOF)"` against `timjstacey/agent-sandbox`.

### Phase C — Implement issues

For each issue, in a fresh worktree (`wt switch feat/<topic>`), Claude 4.6 implements, opens PR via `gh pr create`, merges, removes worktree.

### Phase D — Verification

Run the full Verification checklist (see below) end-to-end once Phase C is complete.

## Verification

End-to-end checks after building:

1. **Build succeeds**: `docker compose build agent` exits 0
2. **Image size sanity**: `docker images agent-sandbox` — expect <600MB; flag if >1GB
3. **User correct**: `docker compose run --rm agent id` → shows agent UID matching host
4. **Mounts work**: inside container, `ls ~/Repositories` shows host repos; `touch ~/Repositories/.agent-write-test` succeeds and shows `agent` owner on host (via ACL inheritance)
5. **Git identity**: `git config user.name` returns host's name
6. **SSH**: `ssh -T git@github.com` succeeds (via forwarded agent)
7. **gh auth**: `gh auth status` shows authenticated state
8. **Claude Code auth**: `claude` launches, no re-login prompt, OAuth credentials present
9. **Node + pkg mgrs**: `node -v` (LTS), `pnpm -v`, `bun -v`, `tsc -v` all succeed
10. **Skills loaded**: `claude` shows caveman + worktrunk in `/skills` list
10a. **Caveman auto-active**: fresh `claude` session greets in caveman mode without user toggling (SessionStart hook fires)
11. **Playwright MCP**: `claude` → MCP servers list includes Playwright, simple browser_navigate call succeeds against test URL
12. **Isolation check**: from inside container, `ls /home/tim` fails (or shows nothing); cannot read host SSH keys at `~/.ssh/` (only socket forwarded)

## Open items to confirm during implementation

- Exact Playwright MCP image tag and transport (SSE port vs stdio) — confirm against Microsoft's published image at build time
- Whether `@anthropic-ai/claude-code` has any native deps that need `build-essential` (verify; pull in only if needed)
- Outbound network: default unrestricted; user can add `network_mode` or firewall rules later if desired (out of scope for initial build)
- **Registry choice for CI image push**: GHCR vs Docker Hub vs self-hosted — decide before wiring `.github/workflows/build.yml` login step

## Amendment — Issue #5: repo-side Claude config (2026-05-26)

Supersedes the "Skills delivery" and "MCP config" rows in the decisions table.

**What changed:** Image no longer bakes Claude configuration. Layers 9b (claude shim), 10 (skills clone), 11 (settings.json bake), 12 (mcp-config.json bake) are gone. The image now carries only the runtime (Debian + Node + claude CLI + tooling). All Claude configuration lives in the repo.

**New scheme:**
- `.claude/settings.json` (committed): `extraKnownMarketplaces` + `enabledPlugins` → caveman and worktrunk fetched from GitHub on first `claude` launch.
- `.claude/mcp-config.json` (committed): Playwright SSE entry, bind-mounted into container via the existing `.claude:/home/agent/.claude` mount.
- Dockerfile Layer 9b replaced with a `bashrc` `claude()` function that forwards `--mcp-config "$HOME/.claude/mcp-config.json"` in interactive shells.
- `bin/agent-sandbox claude` injects `--mcp-config /home/agent/.claude/mcp-config.json` directly (bashrc not in scope for non-interactive docker exec paths).
- `.gitignore` updated to granular per-file ignores inside `.claude/`; `settings.json` and `mcp-config.json` are now tracked.

**Trade-offs:** First launch fetches plugin HEAD (not a pinned commit). Acceptable — network already required for npm/apt/SSH. To pin later: `claude plugin install caveman@<sha>` and promote `installed_plugins.json` to tracked.
