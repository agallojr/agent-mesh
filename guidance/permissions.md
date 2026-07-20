# Permission posture for mesh agents

Mesh agents run unattended. **An agent that blocks on an interactive permission
prompt is a failed agent** -- on a remote node no human is present to approve it,
so it hangs until timeout. The operator's autonomy grant must travel to every
node as committed config, not be re-approved per machine.

## The precedence trap (read this first)

In Claude Code, **`deny` beats `allow` at every scope, with no override**. A broad
deny cannot be re-opened by a narrower allow, at any level (project, local,
enterprise), and a PreToolUse hook's `allow` decision cannot beat a settings
`deny` either. Bash permission rules match the **literal command string** with
`*` globs; they are NOT path-aware. So "allow git only in one repository" cannot
be expressed as a permission rule at all.

## How the mesh gets path-scoped git

Git must actually run **inside the Claude agent** -- the `mesh-on` skill and its
poller commit and push directly; there is no separate launcher. So the blanket
git deny is removed from settings and replaced by a hook that is the sole git
gatekeeper:

1. **`~/.claude/settings.json`** removes the blanket `git add/commit/push` deny
   (keeping `sudo` denied) and registers a `PreToolUse` hook on `Bash`.
2. **`~/.claude/hooks/git-gate.py`** permits `git add/commit/push` ONLY when the
   target repository is on `~/.claude/mesh-git-allowlist.txt`; everywhere else it
   denies them. Read-only git (`pull`, `fetch`, `status`, `log`) is never gated.
   The hook is fail-closed: if it cannot prove the target is allowlisted, it
   denies.
3. **`~/.claude/mesh-git-allowlist.txt`** lists absolute repo paths, one per line.
   The coordination repo is on it. Adding another repo path here is how the
   operator explicitly authorizes an agent to work with that repo; absent an
   entry, gated git there is denied.

These three live in `~/.claude` -- harness config lives centrally, never vendored
per-repo. The coordination repo carries this document so every node knows the
posture; the operator installs the hook + allowlist on each node.

## The literal-path rule (load-bearing for agents)

The hook sees the command **before the shell expands it**. A variable or a
`cd`-then-git therefore cannot be resolved and is denied. Every git command an
agent emits MUST use a literal absolute path:

- Correct:  `git -C /abs/path/to/repo push`
- Denied:   `git -C "$REPO_PATH" push`  (unexpanded variable)
- Denied:   `cd "$REPO_PATH" && git push`  (cwd not trustable to the hook)

Read `REPO_PATH` from identity, then write its literal value into each git
command. This is not optional; it is how the agent stays on the allowed side of
the gate.

## Task-execution permissions

For everything other than git, the node's Claude agent runs under a broad allow
(`Bash`, `Read`, `Edit`, `Write`, `Glob`, `Grep`, `WebSearch`, `WebFetch`) so
task execution never prompts, with `sudo` denied. Piping a downloaded script into
a shell and recursive force-deletes outside the workspace remain off-limits by
convention.

## Node checklist to launch (including an extra test agent)

1. Clone the repo; note its absolute path as `REPO_PATH`.
2. Install the git gate on this node: copy `git-gate.py` to `~/.claude/hooks/`,
   register the `PreToolUse` Bash hook in `~/.claude/settings.json`, remove any
   blanket git deny, and add `REPO_PATH` to `~/.claude/mesh-git-allowlist.txt`.
3. Plant `~/.agent-identity.env` (mode 644) and `~/.agent-credentials.env`
   (`chmod 600` — only the credentials file needs 600).
4. Install the mesh skills: symlink the repo's `skills/mesh-on` and
   `skills/mesh-off` into `~/.claude/skills/`.
5. Start Claude normally, then invoke `/mesh-on`. Stop later with `/mesh-off`.

No step requires a human to approve a permission after launch.
