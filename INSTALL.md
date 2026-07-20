# Installing the mesh on a node

This turns a machine into a mesh node: a Claude agent that joins the
coordination repo, takes tasks addressed to it, and syncs results by git. It
applies equally to the hub laptop and a remote worker. A human runs these steps
once per node (a Claude agent can run them too — they are ordinary shell edits).

Estimated time: a few minutes. Everything installs under `~/.claude` and two
dotfiles in `$HOME`; nothing here is committed to the repo.

## 0. Prerequisites

- `git` and Python 3 (`/usr/bin/python3` is used by the hook; it need not be on
  `PATH`).
- Claude Code installed and working on this machine.
- Network access to the coordination repo's git remote.

## 1. Clone the coordination repo

Pick a stable location and clone. Record its absolute path — you will reuse it as
`REPO` below.

```bash
git clone <coordination-repo-url> ~/agent-mesh
REPO="$HOME/agent-mesh"          # adjust if you cloned elsewhere
echo "REPO=$REPO"
```

## 2. Install the git gate (hook + settings + allowlist)

The mesh agent runs `git add/commit/push` itself. Claude Code's `deny` beats
`allow` everywhere and its rules are not path-aware, so a hook is the only way to
allow git in the coordination repo while denying it elsewhere. Three pieces, all
in `~/.claude`:

**2a. Install the hook.**

```bash
mkdir -p ~/.claude/hooks
cp "$REPO/hooks/git-gate.py" ~/.claude/hooks/git-gate.py
chmod +x ~/.claude/hooks/git-gate.py
```

**2b. Create the allowlist** with this node's repo path (and any other repo you
explicitly want the agent to be able to use git in — one absolute path per line):

```bash
cp "$REPO/hooks/mesh-git-allowlist.txt.template" \
   ~/.claude/mesh-git-allowlist.txt
printf '%s\n' "$REPO" >> ~/.claude/mesh-git-allowlist.txt
grep -v '^#' ~/.claude/mesh-git-allowlist.txt        # confirm your path is in
```

**2c. Register the hook and drop any blanket git deny** in
`~/.claude/settings.json`. The result must contain:

- a `PreToolUse` hook on `Bash` pointing at `~/.claude/hooks/git-gate.py`
  (use the absolute path, not `~`),
- **no** `Bash(git add/commit/push...)` entries in `permissions.deny`
  (the hook now owns those),
- `sudo` still denied.

If you have no `~/.claude/settings.json` yet, start from the snippet:

```bash
sed "s#REPLACE_WITH_HOME#$HOME#g" \
  "$REPO/hooks/settings.snippet.json" > ~/.claude/settings.json
```

If you already have one, merge the `hooks.PreToolUse` entry and the trimmed
`permissions.deny` in by hand (or with `jq`). `hooks/settings.snippet.json` shows
exactly the two keys to add. Do not remove your existing `env`, `model`, or other
settings.

**2d. Verify the gate works** before going further:

```bash
# should print "deny": target repo not on allowlist  (git in /tmp is blocked)
printf '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp add -A"},"cwd":"/tmp"}' \
  | /usr/bin/python3 ~/.claude/hooks/git-gate.py

# should print nothing  (git in the coordination repo is allowed)
printf '{"tool_name":"Bash","tool_input":{"command":"git -C '"$REPO"' add -A"},"cwd":"/tmp"}' \
  | /usr/bin/python3 ~/.claude/hooks/git-gate.py && echo "(allowed)"
```

The first prints a deny JSON; the second prints only `(allowed)`.

## 3. Install the skills (symlinks)

Symlink the repo's two skills into `~/.claude/skills/`. Symlinks (not copies) mean
a `git pull` in the repo updates mesh behavior on this node automatically.

```bash
mkdir -p ~/.claude/skills
ln -sfn "$REPO/skills/mesh-on"  ~/.claude/skills/mesh-on
ln -sfn "$REPO/skills/mesh-off" ~/.claude/skills/mesh-off
```

Verify they resolve:

```bash
ls -l ~/.claude/skills/mesh-on ~/.claude/skills/mesh-off
test -f ~/.claude/skills/mesh-on/SKILL.md         && echo "mesh-on OK"
test -f ~/.claude/skills/mesh-on/poller-prompt.md && echo "poller OK"
test -f ~/.claude/skills/mesh-off/SKILL.md        && echo "mesh-off OK"
```

`-sfn` makes the command idempotent: safe to re-run when the repo path changes
(it replaces the link instead of nesting a link inside the old target).

## 4. Plant identity and credentials

Two dotfiles in `$HOME`, never committed. Copy the templates and fill them in.

```bash
cp "$REPO/templates/agent-identity.env.template"    ~/.agent-identity.env
cp "$REPO/templates/agent-credentials.env.template" ~/.agent-credentials.env
chmod 600 ~/.agent-credentials.env
```

Edit `~/.agent-identity.env`:

- `AGENT_ID` — generate once, never change: `openssl rand -hex 3`. It appears in
  every path that routes to this node.
- `AGENT_NAME` — human-readable, may change freely.
- `AGENT_CONTEXT` — coarse environment class (e.g. `linux-server`,
  `frontier-login`).
- `AGENT_ROLE` — `worker` (or `hub` for the librarian node).
- `POLL_INTERVAL_SEC` — e.g. `300`.
- `REPO_PATH` — the absolute clone path (`$REPO` from step 1). It MUST match the
  allowlist entry from step 2b.

Edit `~/.agent-credentials.env`: put any credentials this node needs, as
`NAME=value` lines. Only the NAMES are ever published (in registration); values
stay local and must never appear in a message, status file, or log.

## 5. Join the mesh

Start Claude Code normally in any directory, then:

```
/mesh-on
```

The skill reads your identity, self-registers this node into `agents/<id>.yaml`,
and spawns a background poller that watches `tasks/<your-id>/`. Your session stays
interactive. To leave:

```
/mesh-off
```

The poller is **session-scoped**: it lives as long as this Claude session. To
keep a node participating unattended, run the session inside `tmux` or `screen`
and leave it open. Closing the session stops the node (as does `/mesh-off`).

## Troubleshooting

- **`/mesh-on` says REPO_PATH is not allowlisted.** The path in
  `~/.agent-identity.env` must appear verbatim in `~/.claude/mesh-git-allowlist.txt`
  (step 2b). Re-run the `grep` there and compare exactly.
- **A git push is denied.** Confirm the command used a literal absolute path
  (`git -C /abs/repo push`), not `git -C "$VAR"` or `cd repo && git push`. The
  hook reads the command before the shell expands it and denies anything it
  cannot resolve. The skills already do this correctly; this only bites hand-typed
  git.
- **A commit is denied though the path is correct.** The gate splits the raw
  command on shell operators (`;`, `&&`, `||`, `|`, `&`, newline) before parsing,
  so a `-m` message containing one of those — or `$(...)` / backticks — breaks the
  parse and is denied. Keep commit messages to plain words and simple punctuation.
- **`/mesh-on` can't find `~/.agent-identity.env` (or the allowlist), or the
  poller never stops.** On some nodes `$HOME` is not the directory the dotfiles
  and `.claude` actually live in (e.g. `$HOME=/opt/x/install` while identity,
  `.claude`, and the `.mesh-stop` sentinel are in `/opt/x`). Then `~` resolves to
  the wrong place. Fix `$HOME` at the point it is set (login profile or env
  script) so `~` matches where the mesh files are, or pass literal absolute paths.
  The git gate itself is immune — it resolves its allowlist from
  `CLAUDE_CODE_CONFIG_DIR`, not `~` — but the skills and sentinel use `~`.
- **The skill doesn't appear.** Confirm the symlinks resolve (step 3) and restart
  Claude Code so it re-scans `~/.claude/skills/`.
- **Nothing happens after `/mesh-on`.** Tasks only start when someone drops a
  message in `tasks/<your-id>/`. Check `git -C "$REPO" pull` shows your
  registration landed and that another node can see `agents/<your-id>.yaml`.

See `spec/PROTOCOL.md` for the full protocol and `guidance/` for how an agent is
expected to behave once running.
