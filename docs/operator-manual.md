# Agent-Mesh Operator Manual

For the human operator who drives the mesh. The normal seat is a **terminal** —
a Claude Code session on a workstation with the bus cloned locally: the
`mesh-post` / `mesh-check` / `mesh-ref` skills are wired in, the ledger is
right there to `grep` and `less`, and maintenance (pin bumps, node repair) is
in reach when you need it. The same model also works from a **phone** (a Claude
chat interface or a lightweight terminal); section 8 covers what changes there.

Either way the interaction model is identical, and it is the whole manual: you
act by *posting to a role* in plain language and by *reading the ledger*, never
by hand-editing coordination state.

## 0. A complete turn, end to end

You say, in plain language:

> "Post to role `build`: run the nightly data export, put the result in the
> outbox, and give me the task id."

Your interface session writes ONE file — the task message — and pushes. The
session replies: *"Posted `20260814T1502-0001` to role `build`."* Then the
mesh takes over, and you watch it in the ledger:

| You look at | You see |
|---|---|
| `status/20260814T1502-0001.json` | `accepted` — node `60ad2c` claimed it (and is alive) |
| same file, later | `running`, then `done` |
| `outbox/60ad2c/20260814T1502-0001-result.md` | the result, with artifact pointers |

Later ask: *"What happened to task `20260814T1502-0001`?"* — the session pulls,
reads those two files, and tells you. Or skip the session entirely: from a
terminal, `git -C /abs/bus pull` and read the files yourself — the ledger is
plain text. That is the whole interaction model: post to a role, read the
ledger. Everything below is detail.

## 1. Mental model

- **Peer-to-peer, role-addressed. No hub.** Every node holds one or more **roles**.
  You address work to a *role*, not a machine, and whichever node holds that role
  claims and runs it. Nodes talk to each other directly; nothing routes through a
  center.
- **Git is the bus.** There is no message broker. Coordination happens entirely
  through append-only files in a private git repo (your bus,
  `agent-mesh-bus-<mesh>`, named for the mesh).
  Every node does `git pull --rebase`, then
  `git submodule update --init --recursive`, does its work, and pushes.
- **Single-writer discipline.** Each node writes only the paths it owns
  (`agents/<id>.yaml`, its own `outbox/<id>/`, and `status/<task-id>.json` for
  tasks it claimed). Conflicts are prevented by construction, not by locking.
- **Your interface session posts to role queues.** You drop a message into a
  role's queue (`tasks/roles/<role>/`) and read the ledger to see what
  happened. Your session writes nothing but that one message file — you are an
  operator, not a node, so you never write status or race anyone.

Rule of thumb: **to make something happen, post to a role; to know what happened,
read the ledger.**

## 2. Your verbs — the `mesh-*` skills

At the terminal, the skills are how you drive. They are symlinked into
`~/.claude/skills/` at install time (from `product/skills/`), so in any Claude
Code session they are one slash-command away. Each SKILL.md is the full
reference; this is the map:

| Skill | Verb | What it does |
|---|---|---|
| `/mesh-post` | SEND | Post one task or query — to a role queue (any holder claims) or a node's direct inbox. Writes one message file, pushes, done. |
| `/mesh-check` | READ | Pull the bus and summarize what's new since your last check: replies to you, results, status changes, new tasks, registrations, lore. Read-only. |
| `/mesh-ref` | FILE | Ingest URLs into the library as `refs` records with summaries — papers/decks/images retrieved into LFS, web pages as pointers. |
| `/mesh-on` | JOIN | Turn THIS machine into a node: spawn the background poller that claims and runs work. Node-side, not an operator action. |
| `/mesh-off` | LEAVE | Stop this machine's poller. |

The operator pair is `mesh-post` + `mesh-check`: send, then pull. The mesh
never pushes to you — you learn every outcome by reading the ledger. `mesh-on`
/ `mesh-off` are for machines that do work; you can be an operator on a machine
that is not a node at all.

## 3. Daily driving

You steer in natural language. The interface session (via the `mesh-post` skill)
turns your intent into one message in a role queue; a node holding that role claims
it and does the real work.

**Inject a single task.** Post a `task.request` to a role, e.g.:

> "Post to role `build`: run the nightly data export and put the result in the
> outbox. Tag it so I can find the status."

Any node holding `build` claims it (accept-as-claim, so exactly one runs it even if
several hold the role) and you track it via `status/<task-id>.json`.

**Launch a workflow** (an autonomous multi-step chain, recorded as
`workflows/<id>.yaml` and driven by the node that owns it): post a request to a role
whose holder drives workflows, e.g.:

> "Post to role `orchestrator`: start a workflow — step 1 fetch the latest source;
> step 2 build it; step 3 run smoke tests; step 4 publish the report to my inbox.
> Chain them and report each step's status."

Workflows advance from a saved **cursor**, so if the driving node restarts it
resumes where it left off — you do not relaunch.

**Phrasing tips.**
- Name the target **role** (or, to pin work to one machine, a node id).
- State the goal and the finish condition ("put the result in my inbox",
  "tag the status so I can find it").
- Name only credential **NAMES**, never values (see section 6).
- Reference large inputs by pointer, not by pasting them.
- Ask for a task/workflow **id** back so you can watch the right file.

## 4. Observing the mesh from the ledger

The ledger is just files in the bus. Read them (in the interface, or with a
quick `git -C /abs/bus pull` then a look) to see state.

| Path | Meaning |
|------|---------|
| `agents/<id>.yaml` | Self-registration; who exists and their `roles`/id. |
| `tasks/roles/<role>/` | A role queue; work waiting for any holder to claim. Also carries `library.submit` items for `role:librarian`, which the librarian drains rather than claims. |
| `tasks/<id>/` | A node's direct inbox (replies, pings, targeted sends). |
| `status/<task-id>.json` | Current state of a task (see section 5). |
| `outbox/<id>/<task-id>-result.md` | A node's published result for a task. |
| `workflows/<id>.yaml` | An in-flight multi-step chain and its cursor. |
| `memory/` | The library (durable knowledge): `lore/` (verified gotchas), `notes/` (research/design), `refs/` (external references), `workflows/` (curated write-ups of finished processes, distinct from the live `workflows/` above), `runs/` (provenance records — the audit trail of result-bearing tasks, which outlives the retention sweep). |

**Read a task's status.** Open `status/<task-id>.json` and look at its state
field. That single file tells you accepted / running / done / failed / blocked, and
its `agent_id` tells you which node claimed it.

**Find a result.** Look in `outbox/<claiming-node-id>/<task-id>-result.md` — the
claiming node is the `agent_id` in the status file. Large binary outputs are
**not** here — they are referenced by pointer in the record's `artifacts` field
(see section 6, blob rule).

**See in-flight workflows.** List `workflows/*.yaml` and read the cursor to see
which step is active and which are done.

**Check who is alive (liveness).** There is no separate heartbeat. `accepted`
*is* the liveness ACK. To prove a node is alive, post a `query` (a ping) to its
direct inbox:

> "Ping node `worker-3`: query its liveness and tell me if it answers."

Proof of life = the node writes `accepted` **and** a `reply` lands back in your
inbox. A `reply` carries `in_reply_to`; it answers a query you sent — treat it as
information to surface, not as a new task.

## 5. Interpreting states

- **accepted** — A node has claimed the task and acknowledged it. This is also
  the liveness signal. The node is alive and intends to work. Its `agent_id` in the
  status file is the claimant.
- **running** — Work is actively in progress.
- **done** — Completed; look for the result in the claimant's `outbox/`.
- **failed** — The node tried and could not finish. Read the status/result for
  the reason; may need a nudge or a real-machine fix.
- **blocked** — Cannot proceed until something is provided. The most common
  variant is **blocked (missing credential NAMES)**: the node is telling you
  *which credentials it needs by name* — e.g. it needs `EXPORT_API_TOKEN`. It
  is **not** asking you to paste the value. Resolution is to ensure that named
  credential exists in the node's `~/.agent-credentials.env` (a maintenance
  action), never to send the secret through the bus.

## 6. Hygiene rules (do not break these)

- **Never paste secrets.** Values from `~/.agent-credentials.env` must never
  appear in a message, status, log, or result. Only credential **NAMES** are
  ever published. If a task needs a secret, name it; do not carry it.
- **Never write coordination state directly.** As an operator you only ever ADD a
  new message file to a role queue (or a node's inbox). Do not hand-edit `status/`,
  other nodes' `outbox/`, or `agents/` yourself — that breaks single-writer
  discipline and can race a node.
- **Large results by pointer only.** Big binaries never go in the bus. They are
  referenced by an **artifact pointer** in the record's `artifacts` field. If
  you need the blob, follow the pointer; do not ask for it inline.

## 7. When something is stuck

**Dead vs idle.** A silent node is not necessarily dead — a node with nothing
claimable is simply idle. To distinguish, ping it (section 4):

> "Ping node `worker-3`. If no accepted/reply within a few minutes, flag it."

- Gets `accepted` + `reply` → alive, just idle. Nothing to do.
- No `accepted`, no `reply` → likely dead or offline. Escalate.

**Dead claimant.** For a task stuck in `accepted`/`running` too long, scan the
ledger: a `status/<id>.json` in a non-terminal state whose `updated` is stale past
its `timeout_min` means its claimant likely died. The `agent_id` in that file names
the node to restart. The mesh does not reap automatically — recovery is a manual
restart of that node, after which its poller resumes and re-claims queued work.

**Maintenance actions (terminal).** Some fixes are maintenance, not steering —
do them in a workstation session with the bus cloned:
- **Bump the submodule pin** to ship a product update mesh-wide (one bus commit
  that repoints `product/`; nodes pick it up on their next pull +
  `submodule update`).
- **Re-install or restart a dead node**, repair its credentials env, or clear a
  wedged git state.
- Do any direct git surgery on the bus.

## 8. Driving from a phone

The same post-to-a-role / read-the-ledger model works away from the
workstation. "Phone" covers seats with different capabilities — what varies is
how each one writes the bus:

- **Claude Code on mobile/web (claude.ai/code), bus cloned.** A real session:
  the repo is pulled into a cloud sandbox, and git read / commit / **push all
  work** (push is restricted to the current branch; the mesh lives on `main`,
  so that is enough). Inference runs on your personal subscription. This seat
  *can* edit code and do maintenance — the limits below are convention, not
  capability.
- **Claude Code session without a bus clone.** `mobile/mesh-post.sh` posts one
  message over the GitHub Contents API (a PAT with Contents read/write, no
  clone, no git) — same PROTOCOL §5 message, one PUT.
- **Claude chat (no code environment, no git at all).** The optional
  `librarian-ingress` Worker (`services/librarian-ingress/`) hands a note to
  the librarian over an authenticated MCP call. Producer only.

Conventions for any phone seat, chosen not forced:

- **Prefer steering.** Post tasks, check status, read results, ping nodes —
  everything in sections 0–7. Leave git surgery, pin bumps, and `product/`
  edits to a workstation session: a cloud session has **no local PreToolUse
  git gate**, so the operator write-set (`guidance/operator-interface.md`) is
  the only guardrail — the reason to hold the discipline is that nothing else
  will.
- **Not a worker node.** Do not run `/mesh-on` from a phone seat; nodes are
  installed machines with identity, credentials, and the gate.
- **Identity.** Phone seats post as the reserved operator id `op-phone`
  (vs `op-main`), so the ledger records which seat sent what.
- **Orient a fresh phone session** in one step: "read
  `guidance/operator-interface.md` and follow it."

## 9. Glossary

- **Bus** — your private bus git repo (`agent-mesh-bus-<mesh>`, one per mesh,
  named for the mesh); the only channel nodes use to coordinate.
- **Role** — a named queue (`tasks/roles/<role>/`) and the unit of addressing. Any
  node may hold several; a role may be held by several nodes.
- **Claim (accept-as-claim)** — how competing holders of a role avoid double-running
  a task: the first to write an `accepted` status and push owns it; the others yield.
- **Product** — the shipped code, living in a `product/` git **submodule**
  pinned to a tagged commit of the `agent-mesh` product repo.
- **Submodule pin** — the exact product commit the bus points at. Bumping it in
  one bus commit rolls a product update out to the whole mesh.
- **Library** — durable shared knowledge under `memory/` (categories `lore`,
  `notes`, `refs`, `workflows`, `runs`), curated by the holder of the
  `librarian` role. `runs` is the durable audit trail of what executed.
- **Workflow** — an autonomous multi-step chain, recorded as `workflows/<id>.yaml`,
  driven by the node that originated it, resumable from its cursor. Its durable
  write-up, once finished, is curated into `memory/workflows/` by the librarian.
- **Operator** — your interface session; not a node, holds no roles, writes only
  new messages into queues.
- **Inbox / outbox** — `tasks/<id>/` is a node's direct inbox; `outbox/<id>/`
  is where it publishes results.
- **Artifact pointer** — a reference in a record's `artifacts` field to a large
  blob stored outside the bus.

---

Summary: You drive the mesh by posting to roles in plain language and reading
the git ledger (agents, status, outbox, workflows) — never by writing
coordination state yourself. The normal seat is a terminal session with the
`mesh-post` / `mesh-check` skills; a phone works for steering. Work is addressed
to a role; any holder claims it. States mean accepted (alive/ack), running,
done, failed, or blocked (often missing credential NAMES, not values). Never
paste secrets, keep big results as pointers, and do maintenance (pin bumps,
dead-node repairs) from a terminal.
