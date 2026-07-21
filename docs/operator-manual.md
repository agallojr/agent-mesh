# Agent-Mesh Operator Manual (Mobile Edition)

For the human operator who drives the mesh from a phone — a Claude chat
interface or a lightweight terminal — not from a full workstation. You observe
and steer; you do not do heavy git surgery in the field. Everything below is
framed so you can act by *asking the hub* in plain language and by *reading the
ledger*, never by hand-editing coordination state.

## 1. Mental model

- **Star topology.** One node is the **HUB** (also librarian and workflow
  driver). All other nodes are **WORKERS**. Workers do not talk to each other
  directly; the hub is the center of the star.
- **Git is the bus.** There is no message broker. Coordination happens entirely
  through append-only files in a private git repo called `agent-mesh-bus`.
  Every node does `git pull --rebase`, then
  `git submodule update --init --recursive`, does its work, and pushes.
- **Single-writer discipline.** Each node writes only the paths it owns
  (`agents/<id>.yaml`, its own `outbox/<id>/`, `status/<its-task-ids>.json`).
  Conflicts are prevented by construction, not by locking.
- **Your interface session messages the hub.** From your phone you drop
  messages into the hub's inbox (`tasks/<hub-id>/`) and read the ledger to see
  what happened. Your session does **not** write coordination state directly —
  it asks the hub, and the hub owns the writes. That is why you never race
  another node.

Rule of thumb: **to make something happen, message the hub; to know what
happened, read the ledger.**

## 2. Daily driving

You steer in natural language. The interface session translates your intent
into a message in the hub's inbox; the hub originates the real work.

**Inject a single task.** Ask the hub to originate a task, e.g.:

> "Hub, please have a worker run the nightly data export and put the result in
> the outbox. Tag it so I can find the status."

The hub creates the task, routes it to a worker's inbox, and you track it via
`status/<task-id>.json`.

**Launch a workflow** (an autonomous multi-step chain across workers, recorded
as `workflows/<id>.yaml` and driven only by the hub):

> "Hub, start a workflow: step 1, fetch the latest source; step 2, build it;
> step 3, run the smoke tests; step 4, publish the report to my inbox. Chain
> them and report each step's status."

Workflows advance from a saved **cursor**, so if the hub restarts it resumes
where it left off — you do not need to relaunch.

**Phrasing tips.**
- State the goal and the finish condition ("put the result in my inbox",
  "tag the status so I can find it").
- Name only credential **NAMES**, never values (see section 5).
- Reference large inputs by pointer, not by pasting them.
- Ask for a task/workflow **id** back so you can watch the right file.

## 3. Observing the mesh from the ledger

The ledger is just files in the bus. Read them (in the interface, or with a
quick `git -C /abs/bus pull` then a look) to see state.

| Path | Meaning |
|------|---------|
| `agents/<id>.yaml` | Self-registration; who exists and their role/id. |
| `tasks/<id>/` | A node's inbox (its incoming work / messages). |
| `status/<task-id>.json` | Current state of a task (see section 4). |
| `outbox/<id>/<task-id>-result.md` | A node's published result for a task. |
| `workflows/<id>.yaml` | An in-flight multi-step chain and its cursor. |
| `mailbox/roles/librarian/` | Library-facing mail for the hub/librarian. |
| `memory/lore/`, `memory/experiments/` | The library (durable knowledge). |

**Read a task's status.** Open `status/<task-id>.json` and look at its state
field. That single file tells you accepted / running / done / failed / blocked.

**Find a result.** Look in `outbox/<owning-node-id>/<task-id>-result.md`. Large
binary outputs are **not** here — they are referenced by pointer in the
record's `artifacts` field (see section 5, blob rule).

**See in-flight workflows.** List `workflows/*.yaml` and read the cursor to see
which step is active and which are done.

**Check who is alive (liveness).** There is no separate heartbeat. `accepted`
*is* the liveness ACK. To prove a node is alive, ask the hub to send it a
`query` (a ping):

> "Hub, ping worker-3 and tell me if it answers."

Proof of life = the node writes `accepted` **and** a `reply` lands back in the
querying inbox. A `reply` carries `in_reply_to`; it answers a query you sent —
treat it as information to surface, not as a new task.

## 4. Interpreting states

- **accepted** — The node has seen the task and acknowledged it. This is also
  the liveness signal. The node is alive and intends to work.
- **running** — Work is actively in progress.
- **done** — Completed; look for the result in the owner's `outbox/`.
- **failed** — The node tried and could not finish. Read the status/result for
  the reason; may need a nudge or a real-machine fix.
- **blocked** — Cannot proceed until something is provided. The most common
  variant is **blocked (missing credential NAMES)**: the node is telling you
  *which credentials it needs by name* — e.g. it needs `EXPORT_API_TOKEN`. It
  is **not** asking you to paste the value. Resolution is to ensure that named
  credential exists in the node's `~/.agent-credentials.env` (a maintenance
  action), never to send the secret through the bus.

## 5. Hygiene rules (do not break these)

- **Never paste secrets.** Values from `~/.agent-credentials.env` must never
  appear in a message, status, log, or result. Only credential **NAMES** are
  ever published. If a task needs a secret, name it; do not carry it.
- **Never write coordination state directly.** From the phone you *message the
  hub*; the hub owns the writes. Do not hand-edit `status/`, other nodes'
  `outbox/`, or `agents/` yourself — that breaks single-writer discipline and
  can race another node.
- **Large results by pointer only.** Big binaries never go in the bus. They are
  referenced by an **artifact pointer** in the record's `artifacts` field. If
  you need the blob, follow the pointer; do not ask for it inline.

## 6. When something is stuck

**Dead vs idle.** A silent node is not necessarily dead — a worker with an
empty inbox is simply idle. To distinguish, ask the hub to ping it (section 3):

> "Hub, query worker-3. If no accepted/reply within a few minutes, flag it."

- Gets `accepted` + `reply` → alive, just idle. Nothing to do.
- No `accepted`, no `reply` → likely dead or offline. Escalate.

**Nudge.** For a task stuck in `accepted`/`running` too long, ask the hub to
re-query the node or re-issue/reroute the task:

> "Hub, that export task has been running an hour with no result. Re-query the
> node and, if it is dead, reassign the task to another worker."

**Escalate to a real machine.** Some fixes cannot be done from the phone. Move
to a full workstation session when you need to:
- **Bump the submodule pin** to ship a product update mesh-wide (one bus commit
  that repoints `product/`; nodes pick it up on their next pull +
  `submodule update`).
- **Re-install or restart a dead node**, repair its credentials env, or clear a
  wedged git state.
- Do any direct git surgery on the bus.

From the phone your job is to *detect and describe* the problem and hand it to
a maintenance session; do not attempt git repair or `product/` edits in the
field.

## 7. Glossary

- **Bus** — the private `agent-mesh-bus` git repo; the only channel nodes use
  to coordinate.
- **Product** — the shipped code, living in a `product/` git **submodule**
  pinned to a tagged commit of the `agent-mesh` product repo.
- **Submodule pin** — the exact product commit the bus points at. Bumping it in
  one bus commit rolls a product update out to the whole mesh.
- **Library / lore** — durable shared knowledge under `memory/lore/` and
  `memory/experiments/`, curated by the librarian (the hub).
- **Workflow** — an autonomous multi-step chain across workers, recorded as
  `workflows/<id>.yaml`, driven only by the hub, resumable from its cursor.
- **Hub / librarian** — the center node; coordinates work, drives workflows,
  and curates the library.
- **Inbox / outbox** — `tasks/<id>/` is a node's incoming work; `outbox/<id>/`
  is where it publishes results.
- **Artifact pointer** — a reference in a record's `artifacts` field to a large
  blob stored outside the bus.

---

Summary: You drive the mesh from your phone by messaging the hub in plain
language and reading the git ledger (agents, status, outbox, workflows) —
never by writing coordination state yourself. States mean accepted (alive/ack),
running, done, failed, or blocked (often missing credential NAMES, not values).
Never paste secrets, keep big results as pointers, and escalate submodule pin
bumps and dead-node repairs to a real-machine maintenance session.
