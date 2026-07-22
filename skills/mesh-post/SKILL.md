---
name: mesh-post
description: Post one task or query into the agent mesh — addressed to a role (any holder claims it) or to a specific node's direct inbox. Writes a single new message file into the coordination repo and pushes it. Use when you (as an operator, or as a node) want to ask a role to do something or ping a node, in the hubless role-addressed mesh. Does not run the poller loop; it just drops one message.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# mesh-post — post one message to a role (or a node)

The mesh is peer-to-peer and role-addressed: there is no hub. To get work done you
drop a message into a **role queue** (`tasks/roles/<role>/`) and whichever node
holds that role claims and runs it. This skill writes exactly one such message and
pushes it. It is the operator's SEND verb (`guidance/operator-interface.md`), and a
node may use it too. It never writes `status/**` and never touches another file.

Collect from the user (ask only for what is missing):

- **target** — a role (posted to `tasks/roles/<role>/`, `to: role:<role>`) or a
  specific node `agent_id` (posted to that node's direct inbox `tasks/<id>/`,
  `to: <id>` — use this only to ping or pin work to one node).
- **type** — `task.request` for work, or `query` for a question / status ask / ping.
- **body** — Goal, Context, Done when, On failure. Make it self-contained: the
  node that claims it has no history with this conversation, so inline every path,
  commit, branch, prior result, and lore id it needs.
- **credentials** (optional) — KEY NAMES the task needs (never values).
- **priority** (optional) — low | normal | high (default normal).

## Step 1 — resolve who you are and where the repo is

```bash
test -f ~/.agent-identity.env && cat ~/.agent-identity.env || echo "NO_IDENTITY"
```

- If `~/.agent-identity.env` exists (you are a node), use its `AGENT_ID` as `from`
  and its `REPO_PATH` as the literal repo path.
- If it does not (you are an operator interface), `from` is a reserved operator id
  — `op-main` on a laptop, `op-phone` on mobile — and the repo is the bus clone in
  this session. Confirm the path with the user if it is not obvious.

## Step 2 — pull, then optionally confirm a holder exists

```bash
git -C /abs/repo pull --rebase
```

For a role target, you may check that some node advertises it (an unstaffed queue
just waits until one comes online — posting anyway is fine):

```bash
grep -l "<role>" /abs/repo/agents/*.yaml    # nodes whose roles include <role>
```

## Step 3 — write ONE message file

- Path (role): `tasks/roles/<role>/<UTC-YYYYMMDDTHHMM>-<seq>-<slug>.md`
- Path (direct node): `tasks/<agent-id>/<UTC-YYYYMMDDTHHMM>-<seq>-<slug>.md`
- `<seq>` is a 4-digit counter making the name unique within that minute — list the
  target directory and pick the next unused (`0001`, `0002`, …). `<slug>` is a
  short kebab-case summary.

Frontmatter + body per `product/spec/PROTOCOL.md` §5:

```markdown
---
schema_version: 1
id: <UTC-YYYYMMDDTHHMM>-<seq>
from: op-main
to: role:build
type: task.request
created: <UTC ISO-8601, e.g. 2026-07-21T04:12:00Z>
priority: normal
credentials: []
depends_on: []
timeout_min: 120
---

## Goal
One sentence: what must be true when this is finished.

## Context
Everything the claiming node needs and cannot infer. Self-contained.

## Done when
Concrete, checkable completion criteria.

## On failure
What to report, and how far to back off before giving up.
```

For a `query` (ping / status ask), the same shape with `type: query`; the body can
be just Goal + Context. The answering node routes a `reply` back into your inbox
(`tasks/<your-from-id>/`), which you pick up later with `mesh-off`'s sibling read —
a CHECK (`git pull` + read `tasks/<your-from-id>/`).

## Step 4 — commit (PLAIN TEXT) and push

Three separate commands, each with the literal repo path. On a node the git gate
requires the literal `-C /abs/repo` and a plain-text message (no `;`, `&&`, `|`,
`$(...)`, backticks):

```bash
git -C /abs/repo add /abs/repo/tasks/roles/<role>/<file>
git -C /abs/repo commit -m "post <type> to role <role> <id>"
git -C /abs/repo push origin HEAD
```

On push rejection (someone else pushed): `git -C /abs/repo pull --rebase` then push
again — your message is a new uniquely-named file, so it never conflicts textually.
Retry up to 3 times, then back off.

## Step 5 — report

Tell the user, in one line: the target (role or node), the message id and path, and
that they will see the outcome (or reply) on their next CHECK of the ledger. You do
NOT wait for it here — no node pushes back to you; the poller on the claiming node
senses the message on its next scan.
