---
name: mesh-check
description: Check the agent mesh for what's new — pull the coordination repo and summarize replies to you, task results, status changes, new tasks, node registrations, and lore since your last check. This is the operator's READ verb, the counterpart to mesh-post's SEND. The mesh never pushes to you; you learn every outcome by pulling the ledger. Use when you (operator or node) want to see responses to what you posted, or catch up on mesh activity. Read-only — never writes the ledger.
allowed-tools: Read, Bash, Glob, Grep
---

# mesh-check — see what's new in the mesh

The mesh is a git-coordinated ledger and **nothing is ever pushed to you**. After a
`mesh-post`, the answer lands in the repo — a `reply` in your inbox for a `query`, a
published result in the claimant's outbox for a `task.request` — and you see it only
when you pull and look. This skill is that look: pull, then summarize what changed
since your last check, most-useful-first. It is the CHECK verb from
`guidance/operator-interface.md`; `mesh-post` is its SEND counterpart.

This is **read-only**. You never write `status/**`, never move or delete a reply, never
touch any ledger file. Reading writes nothing — that invariant is the whole point.

## Step 1 — resolve who you are and where the repo is

```bash
test -f ~/.agent-identity.env && cat ~/.agent-identity.env || echo "NO_IDENTITY"
```

- **Node** (identity present): repo is its `REPO_PATH`; your ids are its `AGENT_ID`
  (direct inbox `tasks/<AGENT_ID>/`). A node's own poller already surfaces replies —
  running mesh-check is still useful to review the wider ledger.
- **Operator interface** (no identity): your `from` id is the reserved operator id —
  `op-main` on a laptop, `op-phone` on mobile. Ask the user which if unclear, and
  confirm the bus clone path. Operators are stateless and keep **no watermark in the
  repo**; the local state file below lives outside it.

Emit every git command with a **literal absolute repo path** — `git -C /abs/repo …` —
never a `$VAR` or `cd`; a PreToolUse hook (on nodes) denies anything it can't resolve.
The commands here are read-only (`pull`, `log`, `diff`, `cat`) and not gated, but keep
the literal path for consistency.

## Step 2 — pull the ledger

```bash
git -C /abs/repo pull --rebase
```

If `pull --rebase` balks and you are a **pure operator** (nothing local to lose), a
`git -C /abs/repo fetch` then `git -C /abs/repo reset --hard origin/main` is the
operator escape hatch. **Never** `reset --hard` on a clone that is also a node or holds
uncommitted work — reset only a throwaway operator clone. If a running poller is
mid-commit, a transient balk is fine: report against local HEAD and move on.

## Step 3 — pick the window (what "new" means)

Report the range `BASE..HEAD`. Choose `BASE` in this order:

1. **Explicit arg** the user gave: a commit SHA, or a time window like `2h` / `30m` /
   `3d`. Resolve a time window to a commit with
   `git -C /abs/repo rev-list -1 --before="2 hours ago" HEAD`.
2. **Your last check**, from the state file `~/.mesh-check-state` (a bare SHA, outside
   the repo so operator state never pollutes the ledger). Read it; if it names a commit
   that still exists (`git -C /abs/repo cat-file -e <sha>^{commit}`), use it as `BASE`.
3. **First-run fallback**: last 24h — `rev-list -1 --before="24 hours ago"`.

If `BASE` resolves empty (window predates the repo) or the user asks for everything,
use the empty-tree sha (`git -C /abs/repo hash-object -t tree /dev/null`) as `BASE` to
show all history. If `BASE == HEAD`, report "nothing new since last check" and stop —
still advance the watermark (Step 5) so the timestamp of the check is current.

Get the changed paths once:

```bash
git -C /abs/repo diff --name-status <BASE>..HEAD
```

## Step 4 — bucket and summarize, most-useful-first

Group the changed paths and report each bucket with a count and a short human summary.
**Read the bodies and summarize in your own words** — do not dump raw files; that
judgment is why this is a skill and not a grep. Buckets, in order:

1. **Replies to you** — Added `tasks/<your-op-id>/*.md` (and `tasks/<AGENT_ID>/*.md`
   if a node) whose `type: reply`. This is what you usually came for. For each: the
   `from`, the `in_reply_to` id (which `query` it answers), and the answer in one line.
2. **Task results** — Added/modified `outbox/<claimant>/<task-id>-result.md`. For each:
   who produced it, what was done, and any artifact pointers (URLs/paths/job-ids). These
   are *published*, not sent — you read them by path.
3. **Status changes** — `status/<task-id>.json`. One line each: task id, `state`
   (`accepted`/`running`/`done`/`failed`/`blocked`), and owning `agent_id`. Call out
   anything `failed`/`blocked` prominently, with its `error`/missing-credential name.
4. **New tasks / messages posted** — Added `tasks/roles/<role>/*.md` and other direct
   inboxes (excluding the replies already covered). Shows work entering the mesh:
   id, `from`, `to`, `type`.
5. **Node registrations** — `agents/*.yaml`. New nodes joining, or a node's
   `repo_commit`/roles drifting between sessions.
6. **Library / lore** — `memory/**`. New or updated durable knowledge (the librarian's
   output); name the record and its category.

An empty bucket is normal — say "none" and move on. If the whole window is empty, say so
plainly: the mesh pushes nothing to you, so silence means no activity, not a fault.

## Step 5 — advance the watermark, then report

Unless the user passed `--peek` (check without advancing) or an explicit SHA/time window
(a one-off view, leave the watermark alone), record the current HEAD so the next
mesh-check shows only what's newer:

```bash
git -C /abs/repo rev-parse HEAD > ~/.mesh-check-state
```

Close with a one-line summary: commits in the window, new HEAD short-sha, and — if you
posted something earlier that has no reply/result yet — a nudge that it's still
outstanding and to check again later. Do **not** reply to any reply, and do **not**
write a status file for one; a reply is information (`operator-interface.md`).

## Relationship to the other mesh verbs

- **mesh-post** — SEND: drop one `task.request`/`query` into a role queue or inbox.
- **mesh-check** — READ: pull and summarize what came back (this skill).
- **mesh-on / mesh-off** — a *node's* background poller, which auto-surfaces replies as
  they arrive. An operator interface has no poller, so mesh-check is how it catches up.
