# Host Setup

One-time preparation steps to run the agent container on your machine. Follow these in order — a fresh host should be ready to run the container by the end.

---

## 1. Create a dedicated `agent` user

The container runs as a non-root user called `agent`. This user must exist on the host so that bind-mounted directories carry the right ownership inside the container.

Steps 1 and 2 require root. If your terminal has `no_new_privs` set (common when the terminal emulator runs as a Flatpak), `sudo <command>` will fail. Switch to a root shell first, then run the commands:

```bash
sudo su
```

Once at a root prompt, create the user. On Arch-based distros (CachyOS, Manjaro, etc.) use `/usr/bin/nologin`; on Debian/Ubuntu use `/usr/sbin/nologin`:

```bash
# Arch-based
useradd -r -m -s /usr/bin/nologin agent
usermod -L agent
exit

# Debian/Ubuntu
useradd -r -m -s /usr/sbin/nologin agent
usermod -L agent
exit
```

What these flags do:

- `-r` — creates a *system* user (UID below the normal user range).
- `-m` — creates a home directory (`/home/agent` or `/var/lib/agent` depending on distro defaults). The container's entrypoint uses this as writable scratch space.
- `-s /usr/sbin/nologin` — prevents interactive login; the account exists only for process ownership.
- `usermod -L` — locks the password, so the account cannot be used with a password even by mistake. It is only accessible from root or from within a container that already runs as this UID.

---

## 2. Build the image

The image must be built with the same numeric UID/GID as the `agent` user on your host. The wrapper script handles this automatically — do not run `docker compose build` directly.

```bash
./bin/agent-sandbox build
```

The script resolves `id -u agent` and `id -g agent` at build time and passes them as `--build-arg` values. The Dockerfile defaults (`AGENT_UID=1500`, `AGENT_GID=1500`) are only a fallback for builds outside the wrapper.

---

## 3. Grant access with ACLs

The wrapper script handles this for you:

```bash
./bin/agent-sandbox setup
```

This grants the `agent` user POSIX ACL access to each required host path and prints a warning for any paths that don't exist yet (e.g. `~/.claude/.credentials.json` before first login). Re-run it after authenticating with Claude Code or GitHub CLI if you hit those warnings.

The script requires `sudo` to call `setfacl`. If your terminal blocks `sudo` due to `no_new_privs` (common in Flatpak terminals), open a native terminal first.

### What the script grants

ACLs are an extension to standard Unix permissions. `setfacl` adds per-user entries on top of the existing owner/group/other bits without altering them. The script applies exactly the following:

| Path | Permission | Reason |
|---|---|---|
| `~` | `x` (traverse) | Home dirs are `700`; agent needs to enter without being able to list |
| `~/.claude` | `rwX` + default `rwX` | Bind-mounted rw so credentials, session history, and refreshed tokens are shared with the host |
| `~/.claude.json` | `rw` | Bind-mounted rw so account state (oauthAccount, userID) is shared — one host login covers the container |
| `~/.gitconfig` | `r` | Bind-mounted read-only so agent can commit with your identity |
| `~/Repositories` | `rwX` + default `rwX` | Agent reads and writes code here; default ACL propagates to new repos |
| `~/.config/gh` | `rwX` + default `rwX` | `gh` may refresh auth tokens at runtime |
| `~/.config/tea` | `rwX` + default `rwX` | `tea` may refresh auth tokens at runtime |

Execute-only (`x`) on a directory means the `agent` user can reach paths inside it but cannot list its contents — a much narrower grant than read.

---

## 4. Why ACLs instead of chown or group membership

Two common alternatives and why they are not used here:

- **`chown agent`** — transfers ownership away from you. You would need `sudo` to edit your own files.
- **`usermod -aG $USER agent`** — adds `agent` to your primary group. Your `umask` typically makes group-readable files readable by `agent`, but it also means `agent` inherits any future files in your home that happen to have group-read set — a much broader grant than intended.

ACLs give targeted, per-path, per-user permissions. The `agent` account is isolated: it can only read or write the specific paths you listed above.

---

## 5. Verify the setup

```bash
./bin/agent-sandbox verify
```

Prints `OK` or `FAIL` for each required permission and exits non-zero if anything fails. Re-run `./bin/agent-sandbox setup` to fix failures, then verify again.

If `sudo -u agent` fails due to `no_new_privs` (Flatpak terminal), open a native terminal to run the verify command.

---

## 6. Note on token refresh

`~/.claude/` and `~/.claude.json` are bind-mounted read-write into the container. Token refreshes and `/login` from either side propagate to the other automatically — no restart required.

If a tool replaces one of these files outright instead of editing in place, the ACL entry is dropped on the new inode. Re-run setup to restore it:

```bash
./bin/agent-sandbox setup
```
