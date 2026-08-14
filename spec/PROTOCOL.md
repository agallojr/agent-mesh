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
- **Single-holder ingress roles** (e.g. `email-monitor`, see §7 and
  `spec/librarian-email-ingress.md`) write only their own `outbox/`, but must be
  held by exactly one node because they drain a shared *external* resource (one
  mailbox); two holders would double-submit. Same one-holder convention, different
  reason than shared-output.

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
/tasks/roles/<role>/           role queue; writer: anyone. task.request/query are
                               claimed (§6); a library.submit to role:librarian
                               rides this same queue but is drained, not claimed (§7)
/tasks/<agent-id>/             direct inbox (replies, targeted sends); writer:
                               anyone except that agent
/status/<task-id>.json         live task state; writer: the agent that claimed it
/outbox/<agent-id>/            results and replies; writer: that agent only
/memory/<category>/            the library — the categories defined in §7
                               (lore/, notes/, refs/, workflows/, runs/); writer:
                               `librarian` role only. No index file: the records
                               are self-describing (§7)
/memory/best-practices.user.md deployment-specific rules (guidance overlay);
                               writer: the operator (NOT the librarian — see §7)
/workflows/<workflow-id>.yaml  LIVE multi-step workflow plans, cursor-driven and
                               in-flight; writer: the node that originated it.
                               Distinct from memory/workflows/ (§7), the librarian-
                               curated DURABLE write-ups of finished processes.
/guidance/CLAUDE.md            bus entry point composing product + user rules;
                               writer: human + operator
/skills/<name>/                instance skill overlays; a bus skill with the same
                               name as a product skill wins at node link time;
                               writer: operator
/BUS_LAYOUT                    layout stamp (integer); writer: operator or the
                               upgrading agent (see §3.3)
/_archive/YYYY-MM/             swept messages and terminal status; writer: `archiver`
/.gitmodules, /product (gitlink)  the product pin; writer: operator only

PRODUCT SUBMODULE (agent-mesh @ recorded pin) — nodes ride the recorded pin
/product/spec/PROTOCOL.md      this document
/product/spec/LAYOUT_VERSION   the bus layout this product version expects (§3.3)
/product/guidance/             best-practices.base.md, agent-operating.md,
                               permissions.md, operator-interface.md
/product/hooks/                git-gate hook + settings snippet + allowlist tmpl
/product/skills/               mesh-on / mesh-off / mesh-post skills
/product/templates/            identity/credentials env templates
/product/upgrades/             one to-<N>.md per bus-layout transition (§3.3)
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
| `memory/lore/**` | holder of the `librarian` role |
| `_archive/**` | holder of the `archiver` role |
| `workflows/<id>.yaml` | the node that originated that workflow |
| `skills/<name>/` | the operator (instance skill overlay) |
| `BUS_LAYOUT` | the operator, or the upgrading agent on a layout bump (§3.3) |

Ownership of `status/<task-id>.json` is not pre-assigned: for a task on a role
queue it is established by the **first node to write an `accepted` status and push**
(the claim, §6). Once claimed, that node is its sole writer.

### 3.2 .gitattributes

```
* -merge
*.pdf  filter=lfs diff=lfs merge=lfs -text
*.png  filter=lfs diff=lfs merge=lfs -text
*.jpg  filter=lfs diff=lfs merge=lfs -text
*.jpeg filter=lfs diff=lfs merge=lfs -text
*.gif  filter=lfs diff=lfs merge=lfs -text
*.webp filter=lfs diff=lfs merge=lfs -text
*.mp4  filter=lfs diff=lfs merge=lfs -text
*.tar  filter=lfs diff=lfs merge=lfs -text
*.zip  filter=lfs diff=lfs merge=lfs -text
*.gz   filter=lfs diff=lfs merge=lfs -text
*.tgz  filter=lfs diff=lfs merge=lfs -text
*.pptx filter=lfs diff=lfs merge=lfs -text
*.docx filter=lfs diff=lfs merge=lfs -text
```

`* -merge` first: coordination files are single-writer and records are prose, so
a same-path collision must surface as a conflict to be re-derived (§8), never be
silently auto-merged. There is no union-merge exception — the library keeps no
committed index (§7), which was the only file that ever justified one. The
`filter=lfs` lines make the stored **reference artifacts** the `refs` category
holds (papers, slides, images — §7) go to git-LFS, so they do not bloat the pack
and are not subject to the gate's 5 MB non-LFS blob limit; these extensions must
match the gate's `LFS_EXTS` (`hooks/git-gate.py`). git-lfs must be available on
every node that clones the bus, or these land as raw blobs.

### 3.3 Layout versioning and upgrades

The versioned thing is the **bus layout** — the directory shapes and file
contracts the product code assumes — not marketing versions and not commits. The
bus states what it is in `BUS_LAYOUT` (an integer at the bus root); the product
states what it expects in `product/spec/LAYOUT_VERSION` (an integer); and the
product documents every transition in `product/upgrades/to-<N>.md`, each written
for an agent to execute idempotently and covering both bus changes and any
node-side steps. Narrative rationale is in `docs/architecture.md` §4.

On every sync — the `mesh-on` poller, or any agent pulling the bus — after
`git pull` + `submodule update` the agent compares the two integers. Equal is the
common case: proceed at zero cost. Bus **behind**: apply `upgrades/to-<bus+1>.md`
… up to `LAYOUT_VERSION` in order, stamping `BUS_LAYOUT` after each, then proceed
— the agent does exactly what each note says, commits via the gated flow, and
resumes. The whole upgrade is agent-driven and invisible to the operator.

Bus **ahead** of the product checkout means this product is too old for this bus:
**stop and report, never guess forward.** Because nodes ride the recorded pin
(below), an upgrade reaches a node only when the operator — or the upgrade flow
itself — advances the pin, so one bad push to product `main` cannot break a fleet.

**Pin modes.** Adopter mode (the default): `submodule update` *without* `--remote`;
a node runs exactly the product commit the bus records. Developer mode (the product
maintainer's own mesh, opt-in via `MESH_PRODUCT_TRACK=tip` in the node's identity
env): the poller tracks product `main` tip with `--remote`, and the maintainer's
chained-pin tooling advances the recorded pin at each checkpoint. The two modes
differ only in how often the pin moves.

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
librarian — a lore note, a workflow record, or any other category; it generalizes
the older `lore.submit`.) A `library.submit` is posted into the `librarian` role
queue like any other message, but it is **drained, not claimed** — the librarian
folds it into `memory/` (§7) and writes no `status/<id>.json` for it. The queue is
one per role; the message `type` is what tells a consumer whether an item is
claimable work (`task.request`/`query`) or a drain-and-curate submission
(`library.submit`).

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

A status file is **scratch**: it is swept to `_archive/` once terminal (§9), so it
is not the durable record of what a task did. For a result-bearing task the durable
provenance is its `runs/` record (§7), which the executor emits on `done` and which
outlives the sweep. Write the status for live coordination; write the `runs` record
for the audit trail.

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

`memory/` is the durable knowledge store — the **library**. This section is the
**single source of truth** for its structure: the categories below are the whole
set, and nothing elsewhere — a per-category index, a nested folder scheme, a
sibling convention — may define, extend, or contradict it. A record's own
front-matter is authoritative; the library is self-describing, and any catalog or
view over it (see *Indexes* below) is derived from that metadata, never a second
source of truth.

The categories are:

- **`lore/`** — curated, verified operational hints, each a symptom / cause / fix
  / scope note. High-confidence gotchas so a node does not repeat a known
  mistake.
- **`notes/`** — durable research and design knowledge that is not one of the
  narrower kinds below: specs, design docs, comparisons, plans, handoffs,
  experiment logs, trackers. This category is **deliberately broad and is expected
  to grow substantially over time**. Finer subcategories may be introduced later,
  by convention, as an *extension* of this definition — never as a structure that
  competes with it.
- **`refs/`** — external reference artifacts (papers, slides, images, web pages).
  A ref takes one of two shapes: (a) a **stored artifact** — the file is retrieved
  into `refs/` (LFS-tracked, §3.2) alongside a **separate companion `.md` record**
  that carries its metadata and summary, because the artifact itself is binary; or
  (b) a **pointer-only** record — a single `.md` whose front-matter points at the
  source URL, summary in its body, when the source is not worth storing. Retrieve
  documents worth preserving (research papers, decks, images); leave general web
  pages as pointers.
- **`workflows/`** — durable, curated write-ups of multi-agent / multi-node
  processes that ran (layout `project ⊃ workflow ⊃ artifacts`; see below).
- **`runs/`** — durable provenance records of result-bearing tasks: one compact
  record per task that produced a result, capturing the who / what / when / where
  of the run so it outlives the sweep of its scratch (message, status, outbox).
  Emitted by the executor on `done` and promoted by the librarian like any other
  submission; a plain query or a task that produced nothing durable needs none.

New categories are added only by amending this list. Doing so needs no change to
the machinery (the header and submission flow are category-agnostic), but this
section remains their one definition — a category that is not defined here does
not exist.

**Naming — a record's path always contains its `id`.** This is the one naming
invariant, and it is what lets an id-based cross-link resolve to a file with no
lookup table (and no index):

- Flat categories (`lore`, `notes`, `refs`) name each file `<id>-<slug>.md` — the
  `id` first, so files sort by id and a link resolves by globbing `<id>-*`, and a
  human `slug` after, so a directory listing is readable. The `slug` is
  descriptive only: it may be reworded freely because links are by `id`, never by
  filename.
- `workflows` carries the `id` as the workflow folder name (`<project>/<id>/`,
  with `record.md` inside), so the path still contains the id.
- Agent records (`agents/<id>.yaml`) and messages (`<id>-<slug>.md`, §5) already
  satisfy the invariant.

Cross-references between records (`related`, `supersedes`, `wf_ref`,
`discovered_in`) are always by `id`, never by path — so renaming a slug never
breaks a link.

> `memory/workflows/` (durable, curated records of processes that *ran*) is
> deliberately distinct from the top-level `/workflows/` (§8.1), which holds the
> LIVE, cursor-driven plan a node is still driving. Same word, two paths, related
> by design: a live plan finishes, and its write-up is submitted for the
> librarian to fold into `memory/workflows/` with a `wf_ref` back to the plan id.

**One writer: the `librarian` role — for the five categories.** Every path under
the library **categories** — `memory/lore/`, `memory/notes/`, `memory/refs/`,
`memory/workflows/`, `memory/runs/` — is written solely by the holder of the
`librarian` role, for all five, not just lore. A node that does not hold
`librarian` never writes those paths; it submits (below). A node that *does* hold
`librarian` (a worker that is its own librarian) writes them directly and inline,
with no self-submission. Either way the categories have exactly one writer.
(Running two `librarian` holders risks a shared-path collision; single-holder is
an operating convention, §10.) The one file under `memory/` that this rule does
**not** cover is the guidance overlay `memory/best-practices.user.md`: it is the
**operator's** file, not a library record and not a librarian-curated category, so
the operator owns it (§4.4). The single-writer scope here is the five categories;
the overlay's single writer is the operator.

**Common record header.** Every library record, in any category, carries a minimal
header so the records are self-describing (any view can be built from them) and the
archiver knows what to keep:

```yaml
---
schema_version: 1
id: <assigned by the librarian>
title: one line
category: lore            # the memory/<category>/ it belongs to
provenance: worker        # worker | workflow | human
contexts: [frontier-login]   # WHERE it holds — coarse environment class (scopes relevance)
tags: [build, hdf5]          # WHAT it is about — free subject keywords (scopes discovery)
related: []                  # ids of related library records (record↔record cross-links)
discovered_by: a7f3c2                # who learned it (agent id, human, session)
discovered_on: 2026-07-18
discovered_in: 20260720T2132-0001    # origin unit of work — a mesh task id or external session id (may be archived/gone)
source_path: /abs/or/url/of/origin   # where the librarian ingested it from, if any
source_sha256: <hex>                 # checksum of the source at ingest, if a file
ingested_on: 2026-07-20              # when the librarian folded it in
submitted_by: a7f3c2                 # node/agent that posted the library.submit
retention: permanent      # permanent | permanent-until-superseded | archive-after-Nd
---
```

`contexts` and `tags` are two distinct axes, and keeping them apart is what
makes retrieval work: **`contexts`** answers *where a fact is true* (a coarse
environment class — `frontier-login`, `linux-server`, `macos-laptop` — the same
vocabulary as `AGENT_CONTEXT`, §4), while **`tags`** answers *what it is about*
(free subject keywords — `solverfw`, `quantum-cfd`, `entropy-knee`). Do not
overload `contexts` with subjects; a record with no environment scope leaves
`contexts` empty and relies on `tags`. The ingest-provenance fields
(`source_path`, `source_sha256`, `ingested_on`, `submitted_by`) are filled by the
librarian at fold-in and are what let it dedupe, re-verify, and detect a stale
source; leave any that do not apply (e.g. a fact with no file origin) unset.

`related` and `discovered_in` are deliberately separate axes. **`related`** points
at other *library* records (permanent id↔id cross-links) and supersedes the older
ad-hoc `related_lore`. **`discovered_in`** is provenance — the unit of work the
fact came out of (a mesh task id, or an external session id like a Claude
session) — and supersedes the older `related_task`. Task ids decay (§9 sweeps them
to `_archive/` and eventually deletes them), so `discovered_in` is a best-effort
origin trail that may dangle, whereas a `related` id always resolves to a live
record; keeping them in one field would mix a decaying namespace into a permanent
one.

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

**Workflows** is the one category with a nested layout. A `workflows/` record is the durable
write-up of a multi-agent / multi-node process that ran — what it did, who took
part, and how it ended — so a later reader can understand or replay it without the
originating node's history.

Its layout is three levels — **project ⊃ workflow ⊃ artifacts** — because several
physical workflows may feed one project over time, and each workflow may leave
more than one artifact:

```
memory/workflows/
  qtscope-data/                        <- PROJECT (a `project:` handle)
    channelflow-ingest/                <- one workflow (its `id` == this slug)
      record.md                        <- the write-up (frontmatter below)
      channelflow-experiment-log.md    <- an artifact
    <next-workflow>/
      record.md
      <artifacts…>
```

The workflow `id` is a **readable, pinned slug** (not a date+seq), a `project:`
field names the enclosing project, and `wf_ref` is a **list** (a project's live
plans may be several). It adds these process-specific fields on top of the common
header:

```markdown
---
schema_version: 1
id: channelflow-ingest          # readable slug == the workflow's folder name
title: Ingest genode's experiment log into the library
category: workflows
project: qtscope-data           # enclosing project folder
provenance: workflow
contexts: [linux-server, macos-laptop]
tags: [librarian, ingest, channelflow]
related: [lore-20260720-0006]
discovered_by: 241f3c
ingested_on: 2026-07-20
wf_ref: [wf-20260720T1954-2ed1] # the live /workflows/<id>.yaml plan(s) this records
participants: [241f3c, 60ad2c]  # agent ids that took part
nodes: [macos-laptop, genode]   # hosts involved
roles: [librarian]              # roles exercised
started: 2026-07-20T19:54:00Z
ended: 2026-07-20T20:07:00Z
outcome: done                   # done | failed | abandoned
retention: permanent-until-superseded
---

## Goal
What the process set out to make true.

## Steps
The ordered steps as they actually ran (one line each), with the role queue each
targeted and the result that advanced the cursor.

## Outcome
What is now true, where the durable artifacts landed, and any follow-on left open.

## Artifacts
Each sibling file in this workflow folder, one line on what it is.
```

**Runs** is the audit category. A `runs/` record is the durable provenance of a
single result-bearing task — assembled from that task's message, status, and
result at the moment it finishes, so the trail survives after the scratch is swept
(§9). It is what makes a one-off task auditable, the same way a `workflows/` record
makes a multi-node process auditable. The executor emits it as a `library.submit`
on `done`; the librarian promotes it. It adds these run-specific fields on top of
the common header:

```markdown
---
schema_version: 1
id: run-20260721-0400          # librarian-assigned, <cat>-<date>-<seq>
title: 48^3 entropy sweep on tier2_48
category: runs
provenance: worker
task_id: 20260721T0400-0001    # the originating task (may later archive/decay)
agent: 60ad2c                  # executor agent id
contexts: [linux-server]       # where it ran (environment class / backend)
tags: [entropy-knee, channelflow, sweep]
started: 2026-07-21T04:02:40Z  # UTC, from the status transitions
ended: 2026-07-21T04:06:54Z
outcome: done                  # done | failed
retention: permanent-until-superseded
---

## What ran
One or two lines: the task's goal and how it was actually run.

## Result
The key outcome in a sentence, numbers with units (best-practices §24).

## Artifacts
Each durable output as a pointer, with a `sha256` where it is a fixed blob — the
same integrity discipline as the workflow record's `source_sha256`. Never a
payload.
```

Because the `runs` record is the durable copy, it must stand alone: it carries the
run's essential facts inline (goal, result, artifact pointers) and does not depend
on the `task_id` still resolving — that scratch is expected to be swept.

**Refs — stored artifact + companion record.** When a ref is retrieved and stored,
the binary lands at `memory/refs/<id>-<slug>.<ext>` and its companion record at
`memory/refs/<id>-<slug>.md` — same `id` and `slug`, so they pair and both satisfy
the naming invariant. The companion's front-matter adds, on top of the common
header: `artifact` (the stored file's name, a local pointer), `source_path` (the
origin URL), `source_sha256` (checksum of the stored file — now meaningful, since
it is a fixed blob), and `retrieved_on` (UTC, since a URL's content is mutable). A
pointer-only ref omits `artifact`/`source_sha256` and just carries `source_path`
and `retrieved_on`. Either way the summary is the record body.

**Payloads by pointer, artifacts by LFS.** A record is small text (markdown/JSON).
Two different things it may refer to are handled differently. **Reference
artifacts** — a paper, a deck, an image the `refs` category preserves — are stored
in the bus under LFS (§3.2) and paired with a companion record. **Data / result
payloads** — datasets, model checkpoints, large run outputs — stay OUTSIDE the bus
and are referenced by pointer (a URL, path, or job id); the git gate hard-denies
the data/model blob extensions regardless (`hooks/git-gate.py` `BLOB_EXTS`) and
refuses a non-LFS file over the size limit. This keeps a recursive pull of the
library from becoming a data-lake download while still letting the library hold the
reference documents it is meant to curate.

**Submission flow (`library.submit`).** A node without the `librarian` role drops a
`library.submit` message into `tasks/roles/librarian/` — the librarian's ordinary
role queue — with the record header inline and its `category` set. This is *not* a
claim: the submitter writes no `status/<id>.json`, and no node competes for it.
Each cycle the `librarian` holder scans its queue, and for every `library.submit`
it dedupes, validates the header, assigns the `id`, sets any category-specific
verification (e.g. lore's `verified_on`), writes `memory/<category>/<slug>.md`, and
updates the index. There is no per-submission status file and no outbox result —
the `memory/<category>/` record *is* the outcome. An unstaffed queue simply
accumulates until a librarian runs — correct, not a fault. A node that is its own
librarian performs the same steps inline as it scans its own queue.

This is why there is no separate submissions mailbox: one queue per role is enough.
The librarian is a single-holder role, so the claim/status machinery a task needs
(to pick exactly one runner among competing holders) would be pure overhead for a
submission that one curator drains in bulk. The message `type` carries the
distinction the path used to.

**Staleness (lore).** A lore note unverified for 90 days is set to
`confidence: stale` by the `librarian` holder. Stale notes are still surfaced but
flagged. Re-verification is part of the librarian's job — a wrong operational gotcha
is worse than no gotcha.

**There is no index file — the records are the library.** The single source of
truth is the set of record front-matters; the library is self-describing, and
discovery is a scan (a grep) over that metadata. Do **not** commit any `index.md`
— not a cross-category one, not per-category. A checked-in catalog only
duplicates the records and drifts from them, and it is the librarian's write
effort every cycle for no gain the records don't already provide. If a fast
overview is ever wanted, generate it on demand from the front-matter as a
throwaway view — never a committed, hand-maintained file. Records are expected to
move, merge, and be re-categorized over time; because each carries its own
metadata, any index can be rebuilt from them at any moment.

**Email ingress (second submission source).** Besides nodes and the phone-facing
ingress Worker, a single-holder **`email-monitor`** role may watch a Gmail mailbox
and turn an authenticated message into a `library.submit` on the librarian queue.
It is an ordinary *producer*: it validates the mail (transport auth + sender
allowlist + shared secret), strips the secret before any bus write, and posts the
same `library.submit` envelope above — it never writes `memory/` itself, so the
single-writer rule is unchanged. The librarian drains it identically to any other
submission. Full design in `spec/librarian-email-ingress.md`.

---

## 8. Agent loop

The `mesh-on` skill runs `boot` in the main session, then spawns a background
**poller subagent** that runs `loop`. Each git step uses a literal absolute repo
path (`git -C /abs/repo ...`); the poller dispatches each task to an executor
sub-subagent so its own context stays bounded across cycles. `mesh-off` stops the
loop (a `~/.mesh-stop` sentinel checked at the top of every cycle, plus a direct
stop if the poller was spawned in the current session).

The poller does not poll with its own inference. The mechanical part of the loop
— pull, scan the queues, and sleep until something is claimable — lives in a
portable shell script (`skills/mesh-on/mesh-scan-loop.sh`, bash 3.2+, macOS and
Linux, no external `timeout`) that the poller runs as ONE **synchronous** call
and blocks on. Synchronous is load-bearing: a background child is not guaranteed
to survive the poller ending its turn, and an orphaned scanner silently takes
the node off the mesh while it appears parked. The script exits when it finds a
claimable task or a fresh reply (prints `WORK` + the file paths), when
`~/.mesh-stop` exists (prints `STOP`), or at its idle deadline (prints `IDLE`,
default ~9 min — self-limiting under the harness's hard tool timeout), on which
the poller immediately re-parks with no other action. While it blocks, the
poller is parked on that one tool call and spends zero inference tokens. An
idle node therefore costs zero commits and near-zero tokens (one trivial
re-park per deadline window) — both repo traffic and token spend are
proportional to real work, not to node-count × poll-frequency × uptime. The
read-only `pull`/`submodule update` inside the script are ungated, so the git
gate (which guards only add/commit/push, and only inside the Claude agent) is
unaffected; every gated write still happens inside the poller when it wakes.

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
  0. PARK on the scanner -- ONE SYNCHRONOUS call (zero tokens while it blocks;
     never a background call, which can be orphaned by end-of-turn):
       skills/mesh-on/mesh-scan-loop.sh /abs/repo <AGENT_ROLES> <AGENT_ID> <POLL>
     the script loops internally -- pull --rebase + submodule update --init
     --remote --recursive (a product bump on the bus takes effect here), scan
     tasks/roles/<role>/ for each role plus the inbox tasks/<AGENT_ID>/, and
     sleep POLL between scans -- exiting on:
       STOP (exit 2): ~/.mesh-stop exists -> end cleanly
       WORK (exit 0) + file paths: claimable tasks and/or fresh replies found
       IDLE (exit 5): idle deadline (~9 min, under the tool timeout) -> re-park
         immediately, no other action
     an idle node cycles park -> IDLE -> re-park until work arrives.
  1-2. classify each returned path by message type:
       task.request/task.cancel/query (scanner lists only those with no status
         file) -> claimable work (step 3)
       reply (has in_reply_to; scanner surfaces each once) -> surface it (step 4½)
       library.submit -> not emitted by the scanner; drain-and-curate if you hold
         librarian (step 6). Never claimed, no status file; non-librarian ignores.
  3. CLAIM each candidate: write status -> accepted (agent_id = you) and sync.
       On push rejection, pull --rebase and re-check status/<id>.json: if it now
       exists and is not yours, YIELD (another holder claimed it) and move on; else
       retry the claim. The winning accepted write is both the claim and the
       liveness ACK. (A direct-inbox task has one consumer; the claim never contends.)
  4. task.request: verify creds; status blocked if missing names, else
       status -> running; sync; dispatch executor sub-subagent and wait
       terminal: status -> done | failed; write outbox/<AGENT_ID>/<task-id>-result.md;
       for a result-bearing task, ALSO submit a `runs` record (library.submit, §7)
       so the run's provenance outlives its swept scratch
       (no periodic heartbeat -- status is written only at transitions)
     query: write a reply into the SENDER'S inbox tasks/<sender-id>/ (type: reply,
       in_reply_to: <query id>); status -> done. Replies route to inboxes so the
       sender's own inbox scan senses them -- outboxes are never polled.
  4½. for each reply in your inbox: surface it to the human (from, in_reply_to,
       body) via an out-of-band channel -- a parked poller never ends its turn,
       so transcript output is never delivered; a background poller messages its
       main session (SendMessage to main). A reply is information: no status
       write, no executor, no commit. Never delete it -- the archiver sweep is
       the only cleanup.
  5. submit any durable knowledge as a library.submit into tasks/roles/librarian/
  6. if you hold librarian / archiver / a running workflow, run those duties (below)
  7. re-park on the scanner (back to step 0) -- the sleep/re-pull happens inside
     the script while parked, not as an inline model-driven sleep
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
the `library.submit` messages from its own role queue `tasks/roles/librarian/`,
curates `memory/**`, and re-verifies stale notes;
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
`archiver` role. An agent MUST NOT archive another agent's unprocessed message. A
`library.submit` follows task-message retention (archive after 3 days); since a
staffed `librarian` drains its queue every cycle, a submission is normally promoted
into `memory/` long before that window elapses, so archiving the swept message
loses nothing (the durable copy lives in `memory/`).

**Sweep a task as a unit.** A task's message, its terminal `status/<id>.json`, and
its `outbox/<id>/<id>-result.md` are one closed record — move them together, in the
same sweep commit, never one without the others. A terminal status left behind when
its message is archived is an **orphan**: it makes `status/` grow without bound and
blurs the boundary between live and swept state. The sweep MUST also collect
pre-existing orphans — any terminal `status/<id>.json` whose task message is already
archived or gone is itself moved to `_archive/`. Only **terminal** status is ever
swept; a non-terminal (`accepted`/`running`) status stays live (§6) — it is either
in flight or a dead-node orphan to be diagnosed (staleness query), never retired by
the sweep. The durable provenance of a swept run is its `runs/` record (§7), not
the archived status; archiving therefore loses no audit, it only clears scratch.

**The sweep is observable.** The `git mv` commit that performs it (message
`archive sweep <YYYY-MM>`) is by construction the record of what was retired and
when. Anyone can confirm the boundary is being held with a read-only check:
`status/` should contain **no** terminal record whose task message already lives in
`_archive/`. A non-empty result means the archiver is behind (or not running).

Rationale for short task-message retention: promotion into `memory/` becomes a
deliberate ritual rather than an afterthought, and the coordination repo stays
small enough to clone quickly from a login node.

**`_archive/` is frozen and out of scope for quality assurance.** Once a file is
swept into `_archive/YYYY-MM/` it is a historical record, not live state: it is
not re-validated, re-categorized, re-indexed, or held to the library's structure
rules. Curation (dedupe, verification, staleness, the canonical categories of §7)
applies to live `memory/` only. Do not "tidy" the archive.

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

---

## 12. Non-goals — the plane boundary

The three planes (product / bus / node; see `docs/architecture.md` for the
narrative) have a boundary this protocol does not blur:

- **The product carries no operator content.** No user names, machine paths,
  deployment remotes, or credentials appear anywhere in the product repo. A file
  that names any of those does not belong in the product.
- **The bus carries no personal-notebook content.** The library holds the
  mesh-facing digest of knowledge (§7), not an operator's private research
  notebook. Test: if an agent on another node needs it to act, it is a KB record;
  otherwise it stays out of the bus.
- **Nothing references upward out of the bus.** A bus is complete standing alone;
  neither the product submodule nor any bus file reaches into whatever repo may
  contain the bus.
- **Credentials live only on the node.** They exist solely in
  `~/.agent-credentials.env` (§4.2); every plane above carries credential *names*
  only. This is a designed property, not a convention.
