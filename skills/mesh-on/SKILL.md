---
name: mesh-on
description: Enter agent-mesh worker loop. Spawns a background poller subagent that watches this node's task inbox in the coordination repo, dispatches each task to an executor subagent, and syncs status/results via git. The main session stays interactive; stop with /mesh-off. Use when the user wants this machine to join or resume the mesh.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent, TaskList
---

# mesh-on — join the agent mesh as a worker

You are turning THIS Claude session's machine into an active mesh node. You do
the one-time bootstrap yourself, then spawn a **background poller subagent** that
runs the loop so your own (main) context stays small and interactive. The user
stops the loop later with `/mesh-off`.

Read `${REPO_PATH}/spec/PROTOCOL.md` and `${REPO_PATH}/guidance/agent-operating.md`
if anything here is unclear — this skill is the operational digest.

## The git rule you must never break

A PreToolUse hook gates `git add/commit/push` to allowlisted repos only, and it
sees your command **before the shell expands it**. Therefore:

- Every git command MUST use a **literal absolute path**:
  `git -C /abs/path/to/repo <subcommand> ...`
- NEVER `git -C "$REPO_PATH" ...` or `cd "$REPO_PATH" && git ...` — the hook
  cannot resolve a variable or a post-`cd` directory and will DENY it.
- So: read `REPO_PATH` from identity, then write its literal value into each git
  command you emit. Read-only git (`pull`, `fetch`, `status`) is never gated, but
  use the literal `-C` path anyway for consistency.

## Step 1 — load identity

Source the node's identity (never committed, planted per machine):

```bash
cat ~/.agent-identity.env
```

Extract `AGENT_ID`, `AGENT_NAME`, `AGENT_CONTEXT`, `AGENT_ROLE`,
`POLL_INTERVAL_SEC`, `AGENT_CAPABILITIES` (comma-separated; becomes the
registration `capabilities` list), and `REPO_PATH`. If `~/.agent-identity.env`
is missing, STOP and tell the user to create it from
`templates/agent-identity.env.template` in the repo. `REPO_PATH` must be a literal
absolute path (no `$HOME`/`~`) — if it contains a `$` or `~`, STOP and tell the
user to replace it with the expanded absolute path. Confirm `REPO_PATH` is on the
git allowlist:

```bash
grep -qxF "$(sed -n 's/^REPO_PATH=//p' ~/.agent-identity.env)" \
  ~/.claude/mesh-git-allowlist.txt && echo ALLOWED || echo NOT-ALLOWED
```

If NOT-ALLOWED, STOP: git sync will be denied. Tell the user to add the repo path
(one absolute path per line) to `~/.claude/mesh-git-allowlist.txt`.

## Step 2 — clear any stale stop sentinel

`/mesh-off` works by writing `~/.mesh-stop`. Starting fresh, remove it so the new
poller is not killed on its first check:

```bash
rm -f ~/.mesh-stop
```

## Step 3 — sync and self-register

Using the LITERAL repo path (substitute the real value of `REPO_PATH`):

1. `git -C /abs/repo pull --rebase`
2. Overwrite `agents/<AGENT_ID>.yaml` (this file is yours alone) following the
   schema in PROTOCOL.md §4.3 — include `hostname`, `platform` (`uname -sr`),
   `repo_commit` (`git -C /abs/repo rev-parse --short HEAD`), `capabilities`,
   `credentials_available` (KEY NAMES only, from `~/.agent-credentials.env` — never
   values), and a fresh `registered_at`.
3. Commit and push:
   `git -C /abs/repo add -A` then
   `git -C /abs/repo commit -m "register <AGENT_NAME> (<AGENT_ID>)"` then
   `git -C /abs/repo push origin HEAD`
   On push rejection: `git -C /abs/repo pull --rebase`, re-derive your file
   against current state, retry (3x, then back off). Never resolve textually.

## Step 4 — spawn the background poller subagent

Spawn ONE background subagent (the poller). Give it the concrete identity values
and the literal repo path inline — it has no access to your conversation. Use the
prompt in `poller-prompt.md` in this skill directory as the poller's instructions,
with the placeholders filled in. Spawn with `run_in_background: true` so your main
session returns immediately and stays interactive.

Record the returned poller handle (agent id) in your own context and also note it
for the user, so `/mesh-off` in THIS session can stop it directly. Cross-session,
`/mesh-off` stops it via the `~/.mesh-stop` sentinel regardless.

## Step 5 — report and return

Tell the user, in one or two lines: node name/id, role, context, poll interval,
that the poller is running in the background, and that `/mesh-off` stops it. Then
return control — do NOT block or loop in the main session.
