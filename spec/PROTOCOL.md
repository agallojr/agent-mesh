# Agent Coordination Protocol

**schema_version: 1**
**Status: draft, v1**

A GitHub repository used as a durable, outbound-only message bus and shared
knowledge store for Claude agents running on machines that cannot reach each
other directly.

---

## 1. Design invariants

These are load-bearing. Violating any of them reintroduces problems this
protocol exists to avoid.

1. **Single writer per path.** No two agents ever write the same file. Merge
   conflicts are eliminated by construction, not by resolution strategy.
2. **Append-only messaging, mutable state.** Messages are immutable events.
   Status and registration files are overwritten in place by their sole owner.
3. **No hardcoded machine names.** Agents learn their identity at boot from a
   preplanted file and self-register. Routing is by role and context.
4. **Credentials by name, never by value.** No secret ever enters the repo,
   a message, a status file, a log tail, or an agent transcript.
5. **Self-contained messages.** A fresh agent with no conversational history
   must be able to execute a task from its message alone.
6. **Stable IDs, mutable names.** Paths and references use opaque IDs. Human
   labels are display-only and may change freely.
7. **Never resolve conflicts textually.** On push rejection, re-read current
   state and re-apply intent.

---

## 2. Topology

Peer-to-peer, role-addressed. There is no hub. Every participant is a node that
holds one or more **roles**; work is addressed to a role, not to a machine, and
any node holding that role may claim and run it. Nodes may address each other
directly — cross-node coordination does not pass through any central agent.

A **role** is both a queue (`tasks/roles/<role>/`, which its holders monitor) and
the unit of addressing. A node may hold many roles; a role may be held by many
nodes. When several nodes hold the same role they are competing consumers of its
queue; the accept-as-claim rule (§6, §8) ensures exactly one runs each task.

Roles split by what they write:

- **Per-task-output roles** (e.g. `build`, `install`, `slurm.submit`) write only
  their own `outbox/<agent-id>/<task-id>-result.md`. Any number of nodes may hold
  them; fan-out is unbounded and always conflict-free.
- **Shared-output roles** (e.g. `librarian`, `archiver`) curate a shared namespace
  (`memory/lore/**`, `_archive/**`). These should be held by exactly one node so
  their shared writes stay single-writer. This is an operating convention, not a
  mechanism the mesh enforces — running two holders of a shared-output role risks
  a textual conflict on the shared path, at the operator's own risk.

An **operator** is a person's interface to the mesh (§5, and `operator-interface.md`).
It is not a node: it holds no roles, runs no loop, and never writes `status/**`. It
posts task requests and queries into role queues and reads results from the ledger.

---

## 3. Repository layout

The repo nodes clone is the **bus**. Product code is linked in as a pinned
submodule at `product/`; everything else at the bus root is runtime coordination
state and the library.

```
BUS ROOT (agent-mesh-bus) — node-writable coordination state + library
/agents/<agent-id>.yaml        self-registration; writer: that agent only
/tasks/roles/<role>/           role queue; writer: anyone (claimed via §6)
/tasks/<agent-id>/             direct inbox (replies, targeted sends); writer:
                               anyone except that agent
/status/<task-id>.json         live task state; writer: the agent that claimed it
/outbox/<agent-id>/            results and replies; writer: that agent only
/mailbox/roles/librarian/      lore submissions; writer: anyone
/memory/<category>/            the library — open set of durable-knowledge
                               categories (lore/, experiments/, …); writer:
                               `librarian` role only
/memory/index.md               cross-category library catalog; writer: `librarian`
/memory/best-practices.user.md deployment-specific rules; writer: human + librarian
/workflows/<workflow-id>.yaml  durable multi-step workflow plans; writer: the node
                               that originated the workflow
/guidance/CLAUDE.md            bus entry point composing product + user rules;
                               writer: human + operator
/_archive/YYYY-MM/             swept messages and terminal status; writer: `archiver`
/.gitmodules, /product (gitlink)  the product pin; writer: operator only

PRODUCT SUBMODULE (agent-mesh @ pinned tag) — read-only on nodes
/product/spec/PROTOCOL.md      this document
/product/guidance/             best-practices.base.md, agent-operating.md,
                               permissions.md, operator-interface.md
/product/hooks/                git-gate hook + settings snippet + allowlist tmpl
/product/skills/               mesh-on / mesh-off / mesh-post skills
/product/templates/            identity/credentials env templates
/product/install/              installer + bus-skeleton
```

### 3.1 Writer table

| Path | Sole writer |
|---|---|
| `agents/<X>.yaml` | X |
| `tasks/roles/<role>/` | any agent (new files only) |
| `tasks/<X>/` | any agent **except** X (new files only) |
| `status/<task-id>.json` | the agent that first accepted (claimed) that task |
| `outbox/<X>/` | X (new files only) |
| `mailbox/roles/librarian/` | any agent (new files only) |
| `memory/lore/**` | holder of the `librarian` role |
| `_archive/**` | holder of the `archiver` role |
| `workflows/<id>.yaml` | the node that originated that workflow |

Ownership of `status/<task-id>.json` is not pre-assigned: for a task on a role
queue it is established by the **first node to write an `accepted` status and push**
(the claim, §6). Once claimed, that node is its sole writer.

### 3.2 .gitattributes

```
memory/index.md merge=union
* -merge
```

Union merge is permitted **only** on order-independent line-oriented indexes.
Never on prose.

---

## 4. Bootstrap and identity

Two files are preplanted on each machine. Neither is ever committed to the
repository. Neither is generated by an agent.

### 4.1 `~/.agent-identity.env` (mode 644)

```sh
AGENT_ID=a7f3c2                 # opaque, stable, immutable
AGENT_NAME=frontier-login       # human-readable, mutable, display only
AGENT_CONTEXT=frontier-login    # scopes lore relevance
POLL_INTERVAL_SEC=300
AGENT_ROLES=build,slurm.submit,results.groom,install   # comma-separated roles
REPO_PATH=/ccs/home/agallojr/agent-mesh   # literal absolute path; no $HOME/~
```

`AGENT_ID` is the routing key and appears in paths. Changing it orphans that
agent's queues; treat it as immutable once set. Generate once with
`openssl rand -hex 3`.

`AGENT_NAME` may be changed at any time with no protocol consequence.

`AGENT_CONTEXT` is a coarse environment class used to scope lore. Suggested
values: `frontier-login`, `wsl-laptop`, `linux-server`, `macos-laptop`.
Agents sharing a context can trust each other's operational lore; agents in
different contexts should treat it as advisory.

`AGENT_ROLES` is a comma-separated list of the roles this node holds; it is the
source of the `roles` list in registration (§4.3). Each role is a queue the node
monitors (`tasks/roles/<role>/`) and the unit senders address. A lone legacy
`AGENT_ROLE` is read as a one-role list for back-compat. `REPO_PATH` MUST be a
literal absolute path (no `$HOME`, `~`, or other expansion) and must appear
verbatim in the node's `~/.claude/mesh-git-allowlist.txt`, or the git gate denies
the mesh's own syncs.

### 4.2 `~/.agent-credentials.env` (mode 600)

```sh
GH_PAT_RESEARCH=ghp_xxxxxxxxxxxx
OLCF_PROJECT_ID=XXX123
```

**Rules:**

- Never committed. Add both filenames to a global gitignore as defense in depth.
- Agents read **key names** from this file for registration. Values are sourced
  into the environment for use and are never emitted anywhere.
- An agent MUST NOT print, log, echo, or include a credential value in any
  message, status file, log tail, or artifact.
- If a task requires a credential name absent from this file, the agent sets
  the task to `blocked` and reports the missing **name**.
- Prefer short-lived, fine-grained, single-repo tokens. On shared login nodes,
  prefer the site's supported credential mechanism where one exists.

### 4.3 Self-registration

On every boot, before processing any task, the agent overwrites
`agents/<AGENT_ID>.yaml`:

```yaml
schema_version: 1
agent_id: a7f3c2
agent_name: frontier-login
context: frontier-login
roles: [build, slurm.submit, results.groom, install]
hostname: login09.frontier.olcf.ornl.gov
platform: "Linux 5.14.21 / Cray SLES 15"
cwd: /ccs/home/agallojr/agent-mesh
repo_commit: abc1234
model: claude-opus-4-8
poll_interval_sec: 300
credentials_available: [GH_PAT_RESEARCH, OLCF_PROJECT_ID]
registered_at: 2026-07-18T14:30:00Z
session_started: 2026-07-18T14:30:00Z
```

`credentials_available` lists key names only, derived mechanically from the
credentials file. Rewriting on every boot doubles as a coarse liveness signal
and catches hostname or capability drift between sessions.

### 4.4 Bootstrap guidance chain (well-known location)

Identity and credentials tell an agent *who it is*. This section tells it *how
to behave*. On boot — after sourcing identity and credentials, before
self-registration — the agent loads its operating guidance from a single
well-known path at the **bus root**:

```
guidance/CLAUDE.md          the well-known entry point; same on every node
```

Because it lives in the bus, every node — laptop or remote — gets
byte-identical, version-controlled instructions from one `git pull`. The entry
point MUST NOT depend on any machine-local path, which remote nodes do not have.
The bus owns the composition (the product never reaches up out of its submodule):
`guidance/CLAUDE.md` `@import`s, in order:

1. `product/guidance/best-practices.base.md` — universal agent + coding
   conventions that ship with the product. Self-contained and publishable; the
   same on every deployment.
2. `memory/best-practices.user.md` — this deployment's operator-specific rules,
   a text record in the bus library (like lore). It rides the same one-pull
   propagation. If absent, only the base rules apply, so a bare product is still
   complete. This is how the operator's environment rules reach every node
   without forking the base file.
3. `product/guidance/agent-operating.md` — how to be a mesh agent: the loop, the
   writer table, message schemas, single-writer discipline, credential-name-only
   rule, and conflict re-derivation. A fresh agent with no history operates
   correctly from this file alone.
4. `product/guidance/permissions.md` — the permission posture (see §4.5).

A node enters mesh behavior through the **`mesh-on` skill**, not through a
per-node `@import`. A human starts Claude normally on the node and invokes
`/mesh-on`; the skill reads this guidance chain, self-registers the agent, and
spawns the poll loop. Launching an extra test agent on a node is then: plant the
two env files (§4.1–4.2), ensure the skills and git gate are installed (§4.5),
and invoke `/mesh-on`.

### 4.5 Permission posture and autonomy propagation

Mesh agents run unattended. **An agent that blocks on an interactive permission
prompt is a failed agent**: on a remote node no human is present to approve it,
so it hangs until timeout. The autonomy the operator has granted must travel to
every node as version-controlled config, not be re-approved per machine.

**Precedence rule that shapes this design:** in Claude Code, `deny` beats
`allow` at every scope, with no override, and permission rules match the literal
command string (they are not path-aware). A broad `git` deny therefore cannot be
re-opened by any allow, and "allow git only in the coordination repo" cannot be
expressed as a permission rule. Since the mesh agent runs git itself every cycle,
the resolution is a hook, not a launcher:

- **The blanket `git add/commit/push` deny is removed** from the node's
  `~/.claude/settings.json` (`sudo` stays denied), and a `PreToolUse` hook on
  `Bash` is registered.
- **`~/.claude/hooks/git-gate.py` is the sole git gatekeeper.** It permits
  `git add/commit/push` only when the target repo is on
  `~/.claude/mesh-git-allowlist.txt`, and denies them everywhere else. Read-only
  git is never gated. It is fail-closed: an unprovable target is denied.
- **Agents emit git with a literal absolute path** (`git -C /abs/repo push`).
  The hook reads the command before shell expansion, so a variable or a
  `cd`-then-git cannot be resolved and is denied. This is load-bearing; see
  `guidance/permissions.md`.
- **The allowlist is the explicit-authorization mechanism.** The coordination
  repo is on it; adding another repo path is how the operator grants an agent
  git access to that repo.

The hook, the allowlist, and the settings edit live in `~/.claude` (harness
config lives centrally, never vendored per-repo). This document travels in the
repo so every node knows the posture; the operator installs the three pieces per
node. Net effect: the agent syncs the coordination repo freely and never hangs
on a permission, while git elsewhere stays denied by default.

---

## 5. Task messages

Path (role queue): `tasks/roles/<role>/<timestamp>-<seq>-<slug>.md`
Path (direct): `tasks/<target-agent-id>/<timestamp>-<seq>-<slug>.md`
Filename timestamp is UTC `YYYYMMDDTHHMM`. Messages are immutable once pushed.
Most work is posted to a role queue; direct inboxes carry replies and
deliberately targeted sends.

```markdown
---
schema_version: 1
id: 20260718T1432-0001
from: 4b91de
to: role:build
type: task.request
created: 2026-07-18T14:32:00Z
priority: normal            # low | normal | high
credentials: [GH_PAT_RESEARCH]   # to: may be role:<role> or a bare agent_id
depends_on: []
timeout_min: 120
---

## Goal
One sentence. What should be true when this is finished.

## Context
Everything the executing agent needs and cannot infer. Branch names, commit
hashes, paths, prior failures, relevant lore IDs. Assume the reader has no
history with this conversation.

## Done when
Concrete, checkable completion criteria.

## On failure
What to report, and how far to back off before giving up.
```

**Types:** `task.request`, `task.cancel`, `query`, `reply`, `library.submit`,
`library.deprecate`. (`library.submit` carries any durable-knowledge record for the
librarian — a lore note, an experiment log, or any other category; it generalizes
the older `lore.submit`.)

**Addressing:** `to` is normally `role:<role>` — the sender posts into that role's
queue and any holder claims it (§6). `to` may instead be a bare `agent_id` for a
direct send (a reply, or work deliberately pinned to one node). Senders resolve
roles and holders from `agents/*.yaml` (the `roles` list) and never hardcode a
machine name. An operator posts to a role with the `mesh-post` command
(`operator-interface.md`); any node may post to a role queue the same way.

**Replies route to the sender's inbox.** A `reply` (and its `in_reply_to`) is
written as a new file in `tasks/<original-sender-id>/`, not into the responder's
outbox. This lets every node sense the responses to messages it sent using the
same inbox scan it already runs — no node ever polls another node's outbox. The
recipient of a reply treats it as information: it surfaces the reply and writes
no status for it. (Outboxes remain the home for `task.request` *results* —
`outbox/<agent-id>/<task-id>-result.md` — which the requester reads by path when
it wants the artifact pointers, not as a liveness signal.)

---

## 6. Status files

Path: `status/<task-id>.json`. Overwritten in place by the executing agent.

```json
{
  "schema_version": 1,
  "task_id": "20260718T1432-0001",
  "agent_id": "a7f3c2",
  "agent_name": "frontier-login",
  "hostname": "login09.frontier.olcf.ornl.gov",
  "state": "running",
  "accepted": "2026-07-18T14:35:00Z",
  "started": "2026-07-18T14:35:12Z",
  "updated": "2026-07-18T14:51:03Z",
  "progress": "cmake configure complete, compiling",
  "log_tail": ["[ 42%] Building CXX object src/CMakeFiles/..."],
  "artifacts": [],
  "error": null
}
```

Status is written only at real state transitions (`accepted`, `running`,
terminal). There is **no periodic heartbeat** — `updated` is just the timestamp
of the last transition write, not a liveness ping. This keeps an executing node
from churning the repo while work is in progress.

**State machine:**

```
accepted -> running -> done
                    -> failed
                    -> blocked   (missing credential or dependency)
         -> cancelled
```

`log_tail` is capped at 20 lines and MUST be scrubbed of anything
credential-shaped before writing.

`artifacts` holds pointers — repo URLs, filesystem paths, job IDs. Never
payloads. Large results belong in the experiment results repository.

**Claiming a task from a role queue (accept-as-claim).** When several nodes hold
the same role they all see the same queued task. Ownership is resolved with no
coordinator, by the same `accepted` write above:

> To take task `T` off a role queue, create `status/<T>.json` with your `agent_id`
> and `state: accepted`, and **push before doing any work.**

Git serializes pushes to the branch: the first push wins and that node owns `T`.
A loser's push is rejected; it runs `pull --rebase`, sees that `status/<T>.json`
now exists and is not its own, and **yields** — it drops the task and moves on,
having spent only a pull, not a compute run (the claim precedes execution). This is
invariant §1.7 ("never resolve conflicts textually") applied to the claim: the
re-derived intent against current state is "already taken, yield". A task on a
direct inbox `tasks/<id>/` has a single consumer and never contends.

**Liveness by ACK, not heartbeat.** A node proves it is alive by *acting* on its
inbox: reading a message and writing status `accepted` is the acknowledgment. To
check whether a specific node is still alive and listening, any participant drops a
`query` (a ping) into that node's direct inbox (`tasks/<id>/`); the node ACKs by
writing a `reply` into the sender's inbox within a few poll intervals, which the
sender's own inbox scan then surfaces. Silence across several intervals implies the node
is down. There is no timer-driven liveness signal and no idle-node writes — a
node with an empty inbox only pulls, so mesh traffic is proportional to real
work, not to node count. This is the design's answer to hosted-git rate limits.

**Orphan detection.** A task left in `accepted`/`running` with no terminal status
past a generous bound (its `timeout_min`, or a multiple of the owner's
`poll_interval_sec`) is presumed dead. Discerning this is a read-only ledger query
any node or operator can run — scan `status/**` for non-terminal states whose
`updated` is stale, and report the owning `agent_id`. The mesh does not reap:
recovery is manual (restart the named node). Only the owning agent or the human may
transition a task to `failed` — a dead agent cannot report its own death, so
staleness is inferred, never asserted by a third party.

---

## 7. The library (durable memory)

`memory/` is the durable knowledge store — the **library**. It is an **open set of
categories**, not a fixed schema: `memory/<category>/` holds records of one kind of
durable learning. `lore/` (curated operational hints) and `experiments/` (run logs)
are the first two categories; new ones are added by convention, with no protocol
change.

**One writer: the `librarian` role.** Every path under `memory/` is written solely
by the holder of the `librarian` role — for all categories, not just lore. A node
that does not hold `librarian` never writes `memory/`; it submits (below). A node
that *does* hold `librarian` (a worker that is its own librarian) writes `memory/`
directly and inline, with no self-submission. Either way `memory/` has exactly one
writer. (Running two `librarian` holders risks a shared-path collision;
single-holder is an operating convention, §10.)

**Common record header.** Every library record, in any category, carries a minimal
header so one index can span them all and the archiver knows what to keep:

```yaml
---
schema_version: 1
id: <assigned by the librarian>
title: one line
category: lore            # the memory/<category>/ it belongs to
provenance: worker        # worker | workflow | human
contexts: [frontier-login]
discovered_by: a7f3c2
discovered_on: 2026-07-18
retention: permanent      # permanent | permanent-until-superseded | archive-after-Nd
---
```

Category-specific fields may follow. **Lore** is the canonical curated example — it
adds `tags`, `verified_on`, `confidence`, `supersedes`, and a symptom/cause/fix/scope
body:

```markdown
---
schema_version: 1
id: lore-0042
title: HDF5 must precede MPI in link order
category: lore
provenance: worker
contexts: [frontier-login]
tags: [build, cmake, hdf5]
discovered_by: a7f3c2
discovered_on: 2026-07-18
verified_on: 2026-07-18
confidence: high          # high | medium | stale
retention: permanent-until-superseded
supersedes: []
---

## Symptom
What you see when you hit this.

## Cause
Why it happens, if known.

## Fix
Exact commands or configuration. Be specific about where and when.

## Scope
Which machines, versions, or conditions this applies to — and which it does not.
```

**Payloads by pointer.** A record is small text (markdown/JSON). Any heavy payload
it refers to — a dataset, a large result file, a binary — stays OUTSIDE the bus and
is referenced by pointer (a URL, path, or job id) in the record. The library holds
knowledge records and pointers, never large blobs (the git gate rejects blobs
regardless). This keeps a recursive pull of the library from becoming a data-lake
download.

**Submission flow (`library.submit`).** A node without the `librarian` role drops a
`library.submit` message in `mailbox/roles/librarian/` with the record body inline
and its `category` set. The `librarian` holder dedupes, validates the header,
assigns the `id`, sets any category-specific verification (e.g. lore's
`verified_on`), writes `memory/<category>/<slug>.md`, and updates the index. An
unstaffed mailbox simply accumulates until a librarian runs — correct, not a fault.
A node that is its own librarian performs the same steps inline instead of via the
mailbox.

**Staleness (lore).** A lore note unverified for 90 days is set to
`confidence: stale` by the `librarian` holder. Stale notes are still surfaced but
flagged. Re-verification is part of the librarian's job — a wrong operational gotcha
is worse than no gotcha.

**index.md** is the library catalog: a flat list of
`id | category | title | contexts | retention`, one per line, sorted by id.
Order-independent and union-merge safe. The librarian maintains one `memory/index.md`
spanning all categories.

---

## 8. Agent loop

The `mesh-on` skill runs `boot` in the main session, then spawns a background
**poller subagent** that runs `loop`. Each git step uses a literal absolute repo
path (`git -C /abs/repo ...`); the poller dispatches each task to an executor
sub-subagent so its own context stays bounded across cycles. `mesh-off` stops the
loop (a `~/.mesh-stop` sentinel checked at the top of every cycle, plus a direct
stop if the poller was spawned in the current session).

```
boot (mesh-on, main session):
  source ~/.agent-identity.env
  source ~/.agent-credentials.env        (values into env only)
  verify REPO_PATH is on ~/.claude/mesh-git-allowlist.txt
  rm -f ~/.mesh-stop
  git -C /abs/repo pull --rebase
  git -C /abs/repo submodule update --init --recursive   (realize product/ pin)
  load guidance/CLAUDE.md chain          (base + user overlay + operating + perms)
  write agents/<AGENT_ID>.yaml           (overwrite, includes registered_at)
  sync                                   (add / commit / push -- see below)
  spawn background poller subagent; return (session stays interactive)

loop (poller subagent):
  0. if ~/.mesh-stop exists: end cleanly
  1. git -C /abs/repo pull --rebase; git -C /abs/repo submodule update --init
     --recursive   (a product bump on the bus takes effect here)
  2. scan this node's queues: tasks/roles/<role>/ for each role in AGENT_ROLES,
     plus the direct inbox tasks/<AGENT_ID>/. Branch by message type:
       task.request/task.cancel/query with no status file -> claimable work (step 3)
       reply (has in_reply_to) -> information to surface (step 4½)
       nothing claimable and no unsurfaced reply -> write nothing, sleep (idle=pull)
  3. CLAIM each candidate: write status -> accepted (agent_id = you) and sync.
       On push rejection, pull --rebase and re-check status/<id>.json: if it now
       exists and is not yours, YIELD (another holder claimed it) and move on; else
       retry the claim. The winning accepted write is both the claim and the
       liveness ACK. (A direct-inbox task has one consumer; the claim never contends.)
  4. task.request: verify creds; status blocked if missing names, else
       status -> running; sync; dispatch executor sub-subagent and wait
       terminal: status -> done | failed; write outbox/<AGENT_ID>/<task-id>-result.md
       (no periodic heartbeat -- status is written only at transitions)
     query: write a reply into the SENDER'S inbox tasks/<sender-id>/ (type: reply,
       in_reply_to: <query id>); status -> done. Replies route to inboxes so the
       sender's own inbox scan senses them -- outboxes are never polled.
  4½. for each reply in your inbox: surface it to the human (from, in_reply_to,
       body). A reply is information: no status write, no executor, no commit.
       Never delete it -- the archiver sweep is the only cleanup.
  5. submit any lore to mailbox/roles/librarian/
  6. if you hold librarian / archiver / a running workflow, run those duties (below)
  7. sleep POLL_INTERVAL_SEC
```

**`sync`** is three separate commands, each with its own literal `-C /abs/repo`
(a bare `commit`/`push` after `&&` is not a command and silently no-ops):
`git -C /abs/repo add -A`; `git -C /abs/repo commit -m "..."`;
`git -C /abs/repo push origin HEAD`. Skip commit/push when nothing was staged.

**Push conflict handling.** On rejection: `git -C /abs/repo pull --rebase`,
re-read the current state of the file being written, re-apply intent, retry.
Three attempts, then exponential backoff. Never `-X ours`, never `-X theirs`,
never hand-resolve a textual conflict — the agent's job is to re-derive its
intended write against current state.

**Role-specific duties (only if you hold the role):** the `librarian` holder drains
`mailbox/roles/librarian/`, curates `memory/lore/**`, and re-verifies stale notes;
the `archiver` holder runs the retention sweep (§9); a node that originates a
workflow drives it (§8.1). A node holding none of these does none of them.

### 8.1 Workflow orchestration (any node)

Any node may run a **workflow** — a multi-step chain it drives autonomously,
originating each step to a role queue, waiting for that step's terminal status,
then originating the next. The node that originates a workflow owns its record and
is that record's sole writer. Nothing is centralized: workflows are a capability a
node exercises, not a hub privilege.

An operator posts a one-shot `task.request` or `query` and reads results from the
ledger; it does not drive workflows (it writes nothing but queue messages). A node
that wants a chain run either drives it itself or posts the request to a role whose
holder does.

**Durable plan.** A workflow is a repo record `workflows/<workflow-id>.yaml`, sole
writer the originating node, with `state`, a `cursor`, and a `steps[]` list where
each step carries `target` (a `role:<role>` or an `agent_id`), `spec`, the
`task_id` originated for it, `status`, and `result_ref`. Because the plan is in the
repo (not only in the driver's context), a driver that dies mid-workflow — process
kill, token expiry — resumes on restart: it re-reads its own `workflows/` records,
finds `running` ones, and continues from `cursor`.

**Advancement, one step per cycle:** at the cursor, a `pending` step is originated
(write the `task.request` into the target role queue AND update the record in ONE
commit, so task and plan land atomically); a `running` step is checked against its
`status/<task_id>.json` — on `done`, record `result_ref` and advance the cursor (or
finish the workflow); on `failed`, halt the workflow.

**Bounded outbox reads.** Driving a workflow is the ONLY case where a node reads
another node's outbox, and only for a task that workflow originated — to fold a
prior step's result into the next step's task body. A driver never blind-sweeps
outboxes; task results are otherwise consumed from the ledger.

**Idempotence.** Plan-in-record + one-commit-per-transition means a restarted
driver never double-originates (a step already `running` has a `task_id` and a
status file) and never skips (a `pending` step at the cursor is originated).
Retention: workflow records follow terminal-status retention (§9) once `state` is
terminal.

---

## 9. Retention

| Class | Retention |
|---|---|
| Task messages | archive after 3 days |
| Status files, terminal | archive after 7 days |
| Status files, active | never archived |
| Outbox results | archive after 7 days |
| Workflow records, terminal | archive after 7 days |
| Workflow records, running | never archived |
| Library records | per the record's `retention` header (default permanent) |
| Agent registrations | overwritten each boot |

Archiving is a `git mv` into `_archive/YYYY-MM/`, performed by the holder of the
`archiver` role. An agent MUST NOT archive another agent's unprocessed message.

Rationale for short mailbox retention: it makes promotion into `memory/`
a deliberate ritual rather than an afterthought, and keeps the coordination
repo small enough to clone quickly from a login node.

---

## 10. Explicitly out of scope for v1

Deferred until an observed failure demands them:

- Enforced uniqueness (election or leases) for shared-output roles. Single-holder
  is an operating convention; running two `librarian` holders is at your own risk.
- Automated reaping of dead claimants. Staleness is a read-only query and recovery
  is a manual restart (§6).
- A heartbeat registry separate from per-task status.
- Encrypted payloads in-repo.

Adding any of these is a protocol version bump. Every file carries
`schema_version` precisely so that migration can be mechanical.

---

## 11. Failure modes and what survives

The role-addressed topology and the single-writer/append-only invariants determine
exactly what a failure can and cannot destroy.

**Data survives any and every node death.** All coordination state lives in the
GitHub repository and is fully mirrored in every clone. If a node's machine is
lost, the tasks it was sent, the status it wrote, and its outbox replies are all
still in the remote and in every other clone. Bringing a replacement node online
is a `git clone` plus an identity file. There is no per-node state that exists
only locally: an agent writes nothing durable outside its clone.

**No node is a coordination bottleneck.** There is no hub in the path of
cross-node traffic. If the only holder of a role is down, that role's queue simply
accumulates and drains when a holder returns (an unstaffed queue is correct
behavior, §2) — other roles keep running. No node holds unique data that is not
already in the repo, so any node can be rebuilt from the remote by a `git clone`
plus an identity file.

**GitHub is the true single point of failure.** It is the one component whose
loss halts the mesh, and — for the window between the last push and an outage —
the one place where not-yet-pushed local commits could be stranded on a single
machine. Availability of the mesh equals availability of the remote. Mitigation
is conventional (GitHub's own durability; clones are full backups from which a
new remote can be seeded), not protocol-level.

**Partial connectivity degrades gracefully.** A node that cannot reach the
remote keeps its local clone intact and resyncs on reconnect; the outbound-only,
append-only design means a reconnecting node fast-forwards or rebases cleanly
without ever needing to resolve a textual conflict (§8). Concurrent pushes to
different paths race only at the git layer and are handled by pull-rebase-retry.

**Node-to-node addressing is supported.** Any node may post work to any role queue
or to another node's direct inbox; the writer table (§3.1) plus unique filenames
keep this conflict-free without a central authority. The single-writer invariant is
preserved not by forbidding cross-node traffic but by construction: inbox files are
uniquely named, and `status/<task-id>.json` has exactly one writer — the node that
claimed it (§6). What was a policy restriction in the star design is removed here.
