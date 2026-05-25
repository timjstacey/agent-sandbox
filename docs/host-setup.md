# Host Setup

One-time preparation steps to run the agent container on your machine. Follow these in order — a fresh host should be ready to run the container by the end.

---

## 1. Create a dedicated `agent` user

The container runs as a non-root user called `agent`. This user must exist on the host so that bind-mounted directories carry the right ownership inside the container.

```bash
sudo useradd -r -m -s /usr/sbin/nologin agent
sudo usermod -L agent
```

What these flags do:

- `-r` — creates a *system* user (UID below the normal user range).
- `-m` — creates a home directory (`/home/agent` or `/var/lib/agent` depending on distro defaults). The container's entrypoint uses this as writable scratch space.
- `-s /usr/sbin/nologin` — prevents interactive login; the account exists only for process ownership.
- `usermod -L` — locks the password, so the account cannot be used with a password even by mistake. It is only accessible from root or from within a container that already runs as this UID.

---

## 2. Record the UID and GID

Docker needs to build the image with the same numeric UID/GID that exists on your host. Fetch them now:

```bash
id agent
# → uid=1500(agent) gid=1500(agent) groups=1500(agent)
```

You will pass these values when building the image:

```bash
export AGENT_UID=$(id -u agent) AGENT_GID=$(id -g agent)
docker compose build agent
```

---

## 3. Grant access with ACLs

The container bind-mounts several directories from your home folder. Rather than changing file ownership or adding `agent` to your primary group (which would grant it broad access to everything you own), we use POSIX ACLs to give the `agent` user *exactly* the access it needs and nothing more.

ACLs are an extension to standard Unix permissions. `setfacl` adds per-user entries on top of the existing owner/group/other bits without altering them.

### Repositories (read-write)

The agent reads and writes code here. The `-d` (default) flag makes new files and directories created inside `~/Repositories` inherit the same ACL entry automatically, so you do not need to re-run this command after creating a new repo.

```bash
setfacl -R -m u:agent:rwX ~/Repositories
setfacl -R -d -m u:agent:rwX ~/Repositories
```

- `-R` — apply recursively to all existing files and directories.
- `-m u:agent:rwX` — grant the `agent` user read, write, and conditional execute (`X` grants execute on directories and on files that are already executable; it does not make plain text files executable).
- `-d` — set the *default* ACL so new entries inherit the same permissions.

### Claude Code credentials (read-only)

The entrypoint copies `~/.claude/.credentials.json` into the container's writable home on startup. The agent reads the copy; the host file stays untouched. Read-only access is enough.

```bash
mkdir -p ~/.claude
setfacl -m u:agent:r ~/.claude/.credentials.json
```

### Git config (read-only)

The container bind-mounts your `~/.gitconfig` so the agent can commit with your name and email. It never needs to write to this file.

```bash
setfacl -m u:agent:r ~/.gitconfig
```

### gh and tea configs (read-write)

The GitHub CLI (`gh`) and Gitea CLI (`tea`) may refresh their authentication tokens at runtime and write the updated token back to their config files. Read-only access would cause those writes to fail silently or with a confusing error.

These directories must exist before running `setfacl`. If you have not yet authenticated with either tool, run `gh auth login` or `tea login` first to create the config directories, then apply the ACLs.

```bash
setfacl -R -m u:agent:rwX ~/.config/gh ~/.config/tea
setfacl -R -d -m u:agent:rwX ~/.config/gh ~/.config/tea
```

---

## 4. Why ACLs instead of chown or group membership

Two common alternatives and why they are not used here:

- **`chown agent`** — transfers ownership away from you. You would need `sudo` to edit your own files.
- **`usermod -aG $USER agent`** — adds `agent` to your primary group. Your `umask` typically makes group-readable files readable by `agent`, but it also means `agent` inherits any future files in your home that happen to have group-read set — a much broader grant than intended.

ACLs give targeted, per-path, per-user permissions. The `agent` account is isolated: it can only read or write the specific paths you listed above.

---

## 5. Verify the setup

Run these checks before starting the container. Each command tests one permission as the `agent` user.

```bash
sudo -u agent test -r ~/.claude/.credentials.json && echo "credentials: OK"
sudo -u agent test -r ~/.gitconfig && echo "gitconfig: OK"
sudo -u agent touch ~/Repositories/.agent-write-test && echo "repos write: OK"
rm ~/Repositories/.agent-write-test
sudo -u agent sh -c 'touch ~/.config/gh/.agent-write-test && rm ~/.config/gh/.agent-write-test' && echo "gh write: OK"
sudo -u agent sh -c 'touch ~/.config/tea/.agent-write-test && rm ~/.config/tea/.agent-write-test' && echo "tea write: OK"
```

If any command fails (no output or a permission-denied error), re-check the corresponding `setfacl` command in step 3.

---

## 6. Note on token refresh

The `~/.claude/.credentials.json` inside the container is writable (the entrypoint copies it to the agent's home, which is writable). However, writes inside the container do not propagate back to the host.

If your host token is refreshed — for example after running `claude /login` — the container's copy becomes stale. The fix is straightforward: stop the container and restart it. The entrypoint copies the latest host credentials on every start.

Similarly, if `setfacl` grants were set before the host credential file was replaced (some tools write a new file rather than updating in place), re-run the relevant `setfacl` command to restore the ACL entry on the new file:

```bash
setfacl -m u:agent:r ~/.claude/.credentials.json
```
