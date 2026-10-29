---
name: mesh-on
description: Enter the agent-mesh node loop. Spawns a background poller subagent that watches this node's role queues in the coordination repo, claims each task (accept-as-claim), dispatches it to an executor subagent, and syncs status/results via git. The main session stays interactive; stop with /mesh-off. Use when the user wants this machine to join or resume the mesh.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent, TaskList
---

# mesh-on — join the agent mesh as a node

You are turning THIS Claude session's machine into an active mesh node. You do
the one-time bootstrap yourself, then spawn a **background poller subagent** that
runs the loop so your own (main) context stays small and interactive. The user
stops the loop later with `/mesh-off`.

Read `${REPO_PATH}/product/spec/PROTOCOL.md` and
`${REPO_PATH}/product/guidance/agent-operating.md` if anything here is unclear —
this skill is the operational digest. The product code is a submodule of the bus
at `product/`, so spec and guidance live under that prefix.

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

Extract `AGENT_ID`, `AGENT_NAME`, `AGENT_CONTEXT`, `POLL_INTERVAL_SEC`,
the optional `MESH_HEARTBEAT_SEC` (default 900), `AGENT_ROLES` (comma-separated; becomes the registration `roles` list and the set
of `tasks/roles/<role>/` queues this node monitors), `REPO_PATH`, and the optional
`MESH_PRODUCT_TRACK`, `MESH_POLLER_MODEL` and `MESH_EXECUTOR_MODEL`. A lone legacy
`AGENT_ROLE` is read as a one-role list. If `~/.agent-identity.env`
is missing, STOP and tell the user to create it from
`product/templates/agent-identity.env.template` in the bus. `REPO_PATH` must be a
literal
absolute path (no `$HOME`/`~`) — if it contains a `$` or `~`, STOP and tell the
user to replace it with the expanded absolute path. Confirm `REPO_PATH` is on the
git allowlist:

```bash
grep -qxF "$(sed -n 's/^REPO_PATH=//p' ~/.agent-identity.env)" \
  ~/.claude/mesh-git-allowlist.txt && echo ALLOWED || echo NOT-ALLOWED
```

If NOT-ALLOWED, STOP: git sync will be denied. Tell the user to add the repo path
(one absolute path per line) to `~/.claude/mesh-git-allowlist.txt`.

Check the two model settings with the script beside this skill (literal path of
THIS skill directory). Each takes an alias (`opus`, `sonnet`, `haiku`, `fable`)
or a full model id (`claude-` then lowercase letters, digits and `-`, such as
`claude-sonnet-5-5`):

```bash
/abs/path/to/this/skill/mesh-model.sh spawn poller "<MESH_POLLER_MODEL, or empty>"
/abs/path/to/this/skill/mesh-model.sh spawn executor "<MESH_EXECUTOR_MODEL, or the alias of THIS session's model>"
```

Each prints how to spawn that agent (Step 5): `model <alias>`, or
`agent <name>` for a full id (it writes the agent definition
`<config dir>/agents/<name>.md` whose `model:` is that id, since the Agent
tool's `model` parameter takes an alias only). Keep both lines. If either
prints `REFUSED <reason>`, STOP and tell the user the reason. If either also
prints `NEW DEFINITION <path>`, tell the user once, in one line, that
Claude Code loads agent definitions at session start: this session may run
that agent on the id's family alias (the start report then shows a fallback)
until they restart it and run `/mesh-on` again.

## Step 2 — clear any stale stop sentinel

`/mesh-off` works by writing `~/.mesh-stop`. Starting fresh, remove it so the new
poller is not killed on its first check:

```bash
rm -f ~/.mesh-stop
```

## Step 3 — load operating guidance (do this before registering)

Identity tells you *who* you are; this step tells you *how to behave*. Per
PROTOCOL.md §4.4, the bus root holds a single well-known entry point that composes
this deployment's full rule set:

```
${REPO_PATH}/guidance/CLAUDE.md
```

Read it and follow its `@`-import chain in order — the best-practices base, this
deployment's user overlay, `agent-operating.md`, and `permissions.md`. These are
your operating rules for every task this session: autonomy posture, git
literal-path discipline, single-writer rules, credential-name-only handling, and
coding conventions. Load them now, before self-registration, so the rules govern
everything that follows. (`git pull` in the next step keeps this file
byte-identical across all nodes; a fresh clone may need `git -C /abs/repo
submodule update --init --recursive` first so `product/` — which the
chain imports from — is present.)

## Step 4 — sync and self-register

Using the LITERAL repo path (substitute the real value of `REPO_PATH`):

1. `git -C /abs/repo pull --rebase` then
   `git -C /abs/repo submodule update --init --recursive` (adopter mode, the
   default: realize the product commit the bus records — nodes ride the recorded
   pin, they do not chase product `main`). In **developer mode** only — when
   `MESH_PRODUCT_TRACK=tip` is set in `~/.agent-identity.env` — add `--remote`
   (`git -C /abs/repo submodule update --init --remote --recursive`) to track the
   tip of `submodule.product.branch` (`main`). The explicit update, not a
   clone-time `--recurse` flag, is what guarantees the product tree is present.
   Neither op is gated; the git gate only touches add/commit/push.
2. Register by script, with the literal path of THIS skill directory, the
   literal repo path, and the model id of THIS session (from your system
   prompt) on the command line:

   ```
   MESH_SESSION_MODEL=<this session's model id> \
     /abs/path/to/this/skill/mesh-register.sh /abs/repo
   ```

   It overwrites `agents/<AGENT_ID>.yaml` (this file is yours alone) per
   PROTOCOL.md §4.3: `hostname`, `platform`, `repo_commit`, `roles` (from
   `AGENT_ROLES`), `poll_interval_sec` (from `POLL_INTERVAL_SEC`),
   `heartbeat_sec` (from `MESH_HEARTBEAT_SEC`, 900 when unset),
   `credentials_available` (KEY NAMES only, never values), `model`, and a fresh
   `registered_at` and `last_poll`. It then commits that one file through
   `mesh-commit.sh` (beside it) and pushes, retrying a rejected push itself.
   Its last line says how it went:
   - `PUSHED` or `NOTHING TO COMMIT`: registered; go on.
   - `PUSH FAILED`: the commit is local, and the poller's first heartbeat
     push carries it. Tell the user in one line and go on.
   - `REFUSED <reason>`: STOP and tell the user the reason.

   Never stage the whole bus checkout (a stage-all `git add`): in the bus that
   records each submodule's checkout as its pin, and `ignore = all` hides it
   (PROTOCOL §8, "The commit rule").

## Step 5 — spawn the background poller subagent

Spawn ONE background subagent (the poller). Give it the concrete identity values
and the literal repo path inline — it has no access to your conversation. Use the
prompt in `poller-prompt.md` in this skill directory as the poller's instructions,
with the placeholders filled in. Fill in `«SKILL_DIR»` with the literal absolute
path of THIS skill directory (where `poller-prompt.md` and `mesh-scan-loop.sh`
live — the bus's `product/skills/mesh-on/`); the poller needs it to launch the
scan script. The poller prompt itself instructs the poller to load
`${REPO_PATH}/guidance/CLAUDE.md` on startup (it does not inherit the rules you
loaded in Step 3 — it is a fresh context), so the operating rules govern it and
every executor it dispatches. Spawn with `run_in_background: true` so your main
session returns immediately and stays interactive.

**Models.** Spawn the poller the way Step 1's poller line says: for
`model <alias>`, pass `model: <alias>` on the Agent call; for `agent <name>`,
pass `subagent_type: <name>` and no `model`. Unset, the poller runs on `sonnet`:
its loop is mechanical, so it needs no more. Most of what an idle re-park costs
is the cache read of the poller's context, so the deadline below and a small
context cut idle cost more than the choice of model does. If the Agent tool
rejects `subagent_type: <name>` (Claude Code has not loaded a definition just
written), spawn it with `model:` set to the family alias in the id (`opus`,
`sonnet`, `haiku` or `fable`; `sonnet` if none) instead; the start report then
shows the fallback.
Fill `«EXECUTOR_SPAWN»` from Step 1's executor line, written as the Agent-call
parameter it stands for: `model: <alias>`, or `subagent_type: <name>` (with no
`model`). When `MESH_EXECUTOR_MODEL` is unset, that line came from the alias of
the model running THIS session, which executors used to inherit through the
poller. Fill `«POLLER_MODEL_REQUESTED»` with `MESH_POLLER_MODEL`, or `sonnet`.
The poller passes «EXECUTOR_SPAWN» on every executor spawn, so task work never
runs on the poller's model.

**Start report.** The poller's first act is to send this session one message,
`poller model: <its exact model id>`. When it arrives, run

```bash
/abs/path/to/this/skill/mesh-model.sh report "<MESH_POLLER_MODEL, or sonnet>" \
  "<the id it sent>" "<any notice Claude Code showed you when you spawned it>"
```

and show the user its output, verbatim and nothing else: one line
`poller model: <model id>`, and exactly one more line
`model fallback: requested <value>, running <model id>` when the poller is not
on the model asked for (an alias the organization's settings restrict, whose
notice reads `Model "<value>" is restricted by your organization's settings.
Using <id> instead.`, or a full id it could not run on). With no fallback there
is no second line. Polling goes on either way.

While an executor runs (in the background, in an interactive session), the
poller parks the same way on `mesh-wait.sh`, which keeps the heartbeat going
until the executor is done, and never ends its turn to wait.

The poller does NOT burn inference polling. It parks on ONE **synchronous** Bash
call to the shell scanner (`mesh-scan-loop.sh`) — never a background call: a
background child is not guaranteed to survive the poller ending its turn, and an
orphaned scanner takes the node off the mesh while it looks parked. The scanner
pulls and scans the queues and blocks until there is real work, a stop, or its
idle deadline (~4 min), where it returns `IDLE` and the poller immediately
re-parks. The deadline sits under the 5-min prompt-cache TTL, so each re-park
reads the poller's context from cache instead of re-writing it. An idle node
therefore costs near-zero tokens (one cache-read re-park per ~4 min) and one
heartbeat commit per heartbeat interval (900 s by default, about 96 a day):
a scan past that interval rewrites `last_poll` in this node's
`agents/<AGENT_ID>.yaml` and pushes it through `mesh-commit.sh`, so
`mesh-check` can name a node that has stopped polling (after 3 intervals).
The scanner runs on macOS and Linux (bash 3.2+, no external `timeout`).

Pass `MESH_HEARTBEAT_SEC` (from the identity file; 900 when unset) to the
poller the same way: it goes on the scanner and wait command lines, which read
it from their environment.

Pass `MESH_PRODUCT_TRACK` through to the poller so it reaches the scanner. You
sourced `~/.agent-identity.env`, so the value (if any) is in your environment;
absent it, the node is in **pin mode** (adopter, the default). The poller must
put the value on the scanner command line explicitly, e.g.
`MESH_PRODUCT_TRACK=tip «SKILL_DIR»/mesh-scan-loop.sh ...` (developer mode) or a
plain invocation (pin mode). The poller prompt covers this; make sure the poller
knows whether this node sets `MESH_PRODUCT_TRACK=tip`.

The scanner also exits on **layout drift**, and the poller handles it (see the
poller prompt): `UPGRADE` (exit 3) when the bus layout is behind the product's
expected layout — apply `product/upgrades/to-<N>.md` in order, stamp `BUS_LAYOUT`,
commit, relaunch; `STALE_PRODUCT` (exit 4) when the bus is ahead of this product
checkout — report and stop, never guess forward. Both are agent-driven with no
operator involvement.

Record the returned poller handle (agent id) in your own context and also note it
for the user, so `/mesh-off` in THIS session can stop it directly. Cross-session,
`/mesh-off` stops it via the `~/.mesh-stop` sentinel regardless.

## Step 6 — report and return

Tell the user, in one or two lines: node name/id, role, context, poll interval,
that the poller is running in the background, and that `/mesh-off` stops it. Then
return control — do NOT block or loop in the main session.
