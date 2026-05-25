# Host Setup

One-time preparation steps to run the agent container on your machine. Follow these in order — a fresh host should be ready to run the container by the end.

---

## 1. UID matching, not a separate host user

The container's in-image user is called `agent`, but its UID/GID are set at build time to match the host user that builds the image. This means:

- Files written by the container appear on the host owned by **you**, not by a separate `agent` account — no `sudo` needed to edit or delete them.
- The wrapper script (`bin/agent-sandbox build`) automatically passes `--build-arg AGENT_UID=$(id -u) AGENT_GID=$(id -g)`.
- No separate host user, no POSIX ACLs to manage, no group memberships to add.

Earlier versions of this project required a dedicated host `agent` user plus POSIX ACLs on every shared path. That added a privilege barrier between the container UID and your home directory, but at the cost of constant `sudo`-to-edit friction and ACL drift whenever host tools rewrote files atomically. The UID-match approach trades that barrier for ergonomics; see *Security trade-off* below.

---

## 2. Build the image

```bash
./bin/agent-sandbox build
```

The script resolves `id -u` and `id -g` for the invoking user and passes them as `--build-arg` values. The Dockerfile defaults (`AGENT_UID=1000`, `AGENT_GID=1000`) are only a fallback for builds outside the wrapper.

If you later move the repo to a host where your UID differs, rebuild.

---

## 3. Initialise container-local Claude state

```bash
./bin/agent-sandbox setup
```

Creates a repo-local `./.claude/` directory and `./.claude.json` file (both gitignored) owned by the host user. The container's Claude session lives there and is independent of your host's Claude Code login — first container run prompts `/login` once, and credentials persist across runs.

The script also warns if `~/.gitconfig`, `~/.config/gh`, or `~/.config/tea` are missing. Create them (or run `gh auth login` / `tea login`) before launching the container.

No `sudo` is required.

---

## 4. Verify the setup

```bash
./bin/agent-sandbox verify
```

Prints `OK` or `FAIL` for each required path and exits non-zero if anything fails. Re-run `./bin/agent-sandbox setup`, or address the failing item, then verify again.

---

## 5. Security trade-off

Running the container as your host UID means:

- **You lose:** UID-based isolation between the container and your home directory. If a process inside the container escapes its bind mounts (via a symlink-traversal bug or a future bind-mount you add that points at sensitive data), it acts as your UID and can read/write anything you can.
- **You keep:** Docker namespace isolation (the container still cannot see host processes, the host network, or unmounted filesystems), no-sudo-in-container (the in-image `agent` user has no `sudoers` entry), SSH-agent forwarding (private keys never enter the container), and a minimal mounted surface (only `~/Repositories`, three config dirs, and the SSH socket are visible inside).

The threat model this configuration is designed against: untrusted code the agent executes inside `~/Repositories` (npm installs, build scripts, test runners). Such code already runs with your privileges in the host's normal workflow; running it inside the container narrows what it can reach to the mounted paths, even though it runs as your UID.

If you need a stronger boundary — e.g. the agent will run wholly untrusted code with broader filesystem access — enable Docker's `userns-remap` in `/etc/docker/daemon.json` to transparently shift the container's UID to an unprivileged host UID without changing the in-container view.

---

## 6. Note on Claude Code sessions

The container has its own Claude Code session, persisted in the repo-local `./.claude/` directory (gitignored). It is **independent** of your host's Claude Code login — refreshes and `/login` events on either side do not affect the other. Each clone or worktree of this repository has its own container session.

Earlier versions of this project shared `~/.claude/` and `~/.claude.json` between host and container via POSIX ACLs. That sharing was removed because host Claude Code rewrites `~/.claude.json` atomically (write tempfile + rename), which strips any ACL entry on each rewrite and silently broke container access. Repo-local state avoids that entire failure mode.

If you want to wipe the container's session (e.g. switch accounts), delete `./.claude/` and `./.claude.json` then re-run `./bin/agent-sandbox setup`.
