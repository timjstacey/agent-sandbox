# Host Setup

One-time preparation steps to run the agent container on your machine. Follow these in order — a fresh host should be ready to run the container by the end.

---

## 1. Zero host setup required for user identity

The container user is created at runtime by the entrypoint from the invoking host user's identity. `bin/agent-sandbox` derives `HOST_USER`/`HOST_UID`/`HOST_GID` from `id -un`/`id -u`/`id -g` and passes them to the container automatically.

- Files written by the container appear on the host owned by **you** — no `sudo` needed.
- No separate host `agent` user, no build-time UID baking, no POSIX ACLs.
- The image is portable across host users and machines — no rebuild when your UID changes.

---

## 2. Build the image

```bash
./bin/agent-sandbox build
```

No build args needed. The Dockerfile produces a single portable image; user identity is injected at `docker compose run` time.

---

## 3. Initialise container-local Claude state

```bash
./bin/agent-sandbox setup
```

Creates the repo-local `./.claude/` directory and `./.claude.json` file (both gitignored) owned by the host user. The container's Claude session lives there and is independent of your host's Claude Code login — first container run prompts `/login` once and credentials persist across runs.

No `sudo` is required.

---

## 4. First-run provisioning

On the first `./bin/agent-sandbox` invocation, the entrypoint provisions the per-user toolchain (Node, pnpm, bun, Claude Code, TypeScript) into a named Docker volume that backs `$HOME`. This takes **60–120 seconds** on first run; subsequent runs are instant.

Progress is printed as:

```
[entrypoint] first-run provisioning (Node 22 + pnpm + bun + claude)...
```

A marker file (`~/.agent-sandbox-provisioned`) gates re-runs. If provisioning fails mid-way (e.g. network error), the marker is not written and the next run retries from scratch.

**Volume cleanup:** To force re-provisioning, remove the named volume:

```bash
docker volume rm "agent-sandbox-$(id -un)_agent-home"
```

---

## 5. Verify the setup

```bash
./bin/agent-sandbox verify
```

Prints `OK` or `FAIL` for each required path. Re-run `./bin/agent-sandbox setup` or address the failing item, then verify again.

---

## 6. GitHub authentication

**Preferred path (host login):** Run `gh auth login` on the host before starting the container. Host `gh` stores the OAuth token in the system keyring (libsecret). `bin/agent-sandbox` extracts it via `gh auth token` and injects it as `GH_TOKEN` into the container — in-container `gh` picks it up automatically without any keyring service.

**Fallback path (in-container login):** Run `gh auth login` inside the container. This works but stores the token **plaintext** in `~/.config/gh/hosts.yml` (no keyring service in the container). The file is `0600` and lives under a bind mount, so the token persists back to the host config directory. Acceptable for dev sandbox use; prefer host login for higher-sensitivity tokens.

If `~/.config/gh` doesn't exist on the host, `bin/agent-sandbox` creates an empty directory automatically and prints a note — the container still starts.

---

## 7. Multi-user isolation

On a shared Docker daemon, each host user gets an isolated named volume via `COMPOSE_PROJECT_NAME=agent-sandbox-${HOST_USER}`. Different users → different project → different `agent-home` volume → no cross-contamination.

---

## 8. SSH host keys for git remotes

The container has no per-user `~/.ssh` directory. To prevent `git push` and `gh pr create` from failing with `Host key verification failed` on the first SSH connection, the image bakes public host keys for the git remotes this project uses into `/etc/ssh/ssh_known_hosts` at build time.

Currently seeded: `github.com`, `gitea.com`, `gitea.sillysamoyed.com`.

If a remote rotates its host key, or you add a new remote, edit the `ssh-keyscan` line in the `Dockerfile` (Layer 2b) and rebuild with `./bin/agent-sandbox build`.

---

## 9. Security trade-off

Running the container as your host UID means:

- **You lose:** UID-based isolation between the container and your home directory. If a process inside the container escapes its bind mounts, it acts as your UID.
- **You keep:** Docker namespace isolation, SSH-agent forwarding (private keys never enter the container), and a minimal mounted surface (only `~/Repositories`, the Claude state dir, the gh config dir, and the SSH socket are visible inside).

The threat model this configuration is designed against: untrusted code the agent executes inside `~/Repositories` (npm installs, build scripts, test runners). Such code already runs with your privileges in the host's normal workflow; running it inside the container narrows what it can reach to the mounted paths.

If you need a stronger boundary, enable Docker's `userns-remap` in `/etc/docker/daemon.json`.

---

## 10. Note on Claude Code sessions

The container has its own Claude Code session, persisted in the repo-local `./.claude/` directory (gitignored). It is **independent** of your host's Claude Code login.

To wipe the container's session (e.g. switch accounts), delete `./.claude/` and `./.claude.json` then re-run `./bin/agent-sandbox setup`.

**Note:** After switching to runtime user injection, existing `.claude.json` files keyed by `/home/agent/...` paths are stale. Delete and re-run `/login` once inside the container, or accept the dead keys (claude ignores unrecognised entries).
