# Agent-Mesh Operator Manual

For the human operator who drives the mesh. The normal seat is a **terminal** —
a Claude Code session on a workstation with the bus cloned locally: the
`mesh-post` / `mesh-check` / `mesh-ref` skills are wired in, the ledger is
right there to `grep` and `less`, and maintenance (pin bumps, node repair) is
in reach when you need it. The same model also works from a **phone** (a Claude
chat interface or a lightweight terminal); section 9 covers what changes there.

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
- **SWE Pod roles.** The six roles `swe.spec`, `swe.plan`, `swe.lead`,
  `swe.build`, `swe.test` and `swe.review` are per-task-output roles
  (PROTOCOL §2): each holder writes only its own
  `outbox/<agent-id>/<task-id>-result.md`, so any number of nodes may hold
  each one. Registering a node for one means adding it to `AGENT_ROLES` in
  that node's `~/.agent-identity.env`. Nothing else changes: the protocol, the
  guidance and the poller treat them like any other role.
- **Git is the bus.** There is no message broker. Coordination happens entirely
  through append-only files in a private git repo (your bus,
  `agent-mesh-<mesh>`, named for the mesh, section 10).
  Every node does `git pull --rebase`, then updates the bus's code
  submodules, does its work, and pushes.
  Memory spaces mounted under `spaces/` follow their own tips instead. Every
  node clones the core, lore and scratch spaces when it is installed; a
  project space it clones only when it first needs it (section 8).
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
| `/mesh-ref` | FILE | Ingest URLs into the library as `refs` records in core, with summaries — papers/decks/images retrieved into LFS, web pages as pointers. |
| `/mesh-scratch` | SCRATCH | Start, save or end a spike in the mesh's scratch space (`spaces/tmp`); ending one records its outcome (section 10). |
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
| `spaces/core/` | The core space, part of the library (durable knowledge): `notes/` (research/design), `refs/` (external references), `workflows/` (curated write-ups of finished processes, distinct from the live `workflows/` above), `runs/` (provenance records — the audit trail of result-bearing tasks, which outlives the retention sweep), and your overlay `best-practices.user.md`. |
| `spaces/lore/lore/` | The personal lore space's records, the rest of the library: verified operational gotchas. |
| `spaces/tmp/` | The scratch space: one folder per spike, and an outcome file per ended spike. Not library. |

Core, lore and scratch are separate repos mounted in the bus (section 10). A
change in one is a commit in that space's own repo: a pull of the bus does not
show it until the node's next scan pulls the space's tip.

**Read a task's status.** Open `status/<task-id>.json` and look at its state
field. That single file tells you accepted / running / done / failed / blocked, and
its `agent_id` tells you which node claimed it.

**Find a result.** Look in `outbox/<claiming-node-id>/<task-id>-result.md` — the
claiming node is the `agent_id` in the status file. Large binary outputs are
**not** here — they are referenced by pointer in the record's `artifacts` field
(see section 6, blob rule).

**See in-flight workflows.** List `workflows/*.yaml` and read the cursor to see
which step is active and which are done.

**Check who is alive (liveness).** Each live node rewrites `last_poll` in its
own `agents/<id>.yaml` once per heartbeat interval (900 s by default, set per
node as `MESH_HEARTBEAT_SEC` and recorded as `heartbeat_sec`) and pushes it, an
executor's run included; that is about 96 bus commits per node per day.
`mesh-check` reports first, under `Nodes not polling`, every node
whose last poll is older than 3 of its heartbeat intervals (2700 s, 45 min, by
default), so a stopped node can take that long to show, with the tasks it holds
in `accepted` or `running`: such a node has stopped polling, and those tasks
are stuck until it is restarted. A change to `last_poll` alone is the
heartbeat, not news. To prove a node acts on its inbox, post a `query` (a
ping) to its direct inbox:

> "Ping node `worker-3`: query its liveness and tell me if it answers."

Proof of life = the node writes `accepted` **and** a `reply` lands back in your
inbox. A `reply` carries `in_reply_to`; it answers a query you sent — treat it as
information to surface, not as a new task.

## 5. Interpreting states

- **accepted** — A node has claimed the task and acknowledged it. The node
  intends to work; whether it is still polling shows in its `last_poll`
  (`mesh-check`, `Nodes not polling`). Its `agent_id` in the status file is the
  claimant.
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

## 8. Mounting a memory space

A **memory space** (`spec/memory-spaces.md`), such as a SWE Pod Project Space,
is a git repo of records with its own remote and access list. The bus mounts
it as a submodule under `spaces/` and lists it in `spaces.yaml`; the bus
stores only a pointer to it, never its contents. Mounting is yours, by hand,
at a terminal with the bus cloned. No agent mounts a space, and loading one
never changes the bus.

**Mount.** Create the space's repo first, with its `space.yaml`. Then, in the
bus:

```sh
git -C /abs/bus submodule add -b main <space repo url> spaces/proj-<name>
git -C /abs/bus config -f .gitmodules submodule.spaces/proj-<name>.ignore all
```

Add the registry line under `spaces:` in `/abs/bus/spaces.yaml` (an empty
`spaces: []` becomes `spaces:` followed by the line):

```yaml
  - {id: proj:<name>, path: spaces/proj-<name>, access: rw, librarian: librarian}
```

`access` is `rw` when this mesh writes the space, through its librarian, and
`ro` when it only reads it. `librarian` names the role that files records into
the space: the mesh's `librarian` by default, or a `librarian.<label>` role if
another node should manage this space. Then commit and push the mount:

```sh
git -C /abs/bus add -- .gitmodules spaces/proj-<name> spaces.yaml
git -C /abs/bus commit -m "mount space proj-<name>"
git -C /abs/bus push origin HEAD
```

`branch = main` (from `-b main`) and `ignore = all` make nodes follow the
space's tip without the gitlink showing as drift. Bump the gitlink only for a
deliberate checkpoint, in its own bus commit (memory-spaces §4.2).

**What nodes do with it.** Every node gets the mount on its next pull, but none
clones the space until it first needs it: a session's "load proj:<name>" (the
`mesh-load` skill), or a claimed task whose `project:` names it. From then on
that node's scanner pulls the space's tip each cycle; it never clones a space
itself. To see which submodule paths a node's scanner updates (it prints them
and exits, before any pull):

```sh
MESH_SCAN_LIST=1 /abs/bus/product/skills/mesh-on/mesh-scan-loop.sh /abs/bus
```

A task that names a space this bus does not mount ends `blocked` with
`NOT MOUNTED proj:<name>` in its status; mount the space, then post the task
again.

**Access.**

- **Read:** every pod node needs read access to the space's repo, as does any
  node whose sessions load it. A node without it cannot clone the space, and
  its tasks for that project end `blocked`.
- **Push:** only the node that holds the space's librarian role gets push
  credentials for the space. It is the space's only mesh writer, filing
  through the `space-librarian` skill. No other node pushes to the space.
  Name the credential in that node's `~/.agent-credentials.env` and nowhere
  else. The scratch space is the one exception: it has no librarian, and
  every node of the mesh pushes to it (section 10).

**Retire.** Unmount a space without touching its repo, which can be mounted
again later:

```sh
git -C /abs/bus submodule deinit -f spaces/proj-<name>
git -C /abs/bus rm spaces/proj-<name>
```

Remove its line from `spaces.yaml`, then commit and push as for a mount.
Records that cite the space keep their ids and stop resolving on this mesh.

## 9. Driving from a phone

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

## 10. The bus, its spaces and their names

This product version expects a split bus: the bus holds only coordination,
mesh configuration and mounts, and the library and the agents' scratch live in
three memory spaces, each its own repo. A bus that still keeps them in its own
`memory/` and `agent-tmp/` folders, the layout before the split, is split once,
by the procedure of section 11.

```
agents/ tasks/ status/ outbox/ workflows/ _archive/   coordination
guidance/ skills/ spaces.yaml .gitmodules BUS_LAYOUT  mesh configuration
.gitignore .gitattributes
product/                              the product, and any other code submodule
spaces/core/                          submodule, repo <owner>-core
spaces/lore/                          submodule, repo <owner>-lore
spaces/tmp/                           submodule, repo agent-mesh-<mesh>-tmp
spaces/proj-<name>/                   project spaces (section 8)
memory/lore                    -> ../spaces/lore/lore        the seven
memory/notes                   -> ../spaces/core/notes       compatibility links,
memory/refs                    -> ../spaces/core/refs        removed by a later
memory/runs                    -> ../spaces/core/runs        change
memory/workflows               -> ../spaces/core/workflows
memory/best-practices.user.md  -> ../spaces/core/best-practices.user.md
agent-tmp                      -> spaces/tmp
```

| Space | Holds | Who writes it |
|---|---|---|
| core, `spaces/core/` | the library's `notes/`, `refs/`, `runs/` and `workflows/`, and your guidance overlay `best-practices.user.md` | the librarian, filing each record through `space-librarian`; the overlay: you, by hand |
| personal lore, `spaces/lore/` | the library's `lore/`, read at `spaces/lore/lore/` | the librarian, through `space-librarian` |
| scratch, `spaces/tmp/` | one folder per spike, a `<spike>.outcome.md` per ended spike, and `README.md` | any agent of this mesh, through `mesh-scratch`; your sync tool may check it in and push it |

Each space also has `space.yaml`, `.gitattributes` and `.gitignore` at its
root. The bus lists the three in `spaces.yaml`:

```yaml
spaces:
  - {id: core, path: spaces/core, access: rw, librarian: librarian}
  - {id: lore, path: spaces/lore, access: rw, librarian: librarian}
  - {id: tmp, path: spaces/tmp, access: rw, librarian: none}
```

`librarian: none` means the space has no librarian, and any agent of this mesh
writes it; only scratch has it. Each `.gitmodules` entry has `branch = main` and
`ignore = all`, and every node keeps its three checkouts on their `main`
branch, so that each pull follows the space's tip (memory-spaces §4.2).

**The overlay.** The bus's `guidance/CLAUDE.md` imports your private rules as
`@../spaces/core/best-practices.user.md`. The overlay is your file, not a
library record: edit it in core and commit and push it there yourself, and
each node gets it at its next scan:

```sh
git -C /abs/bus/spaces/core add -- best-practices.user.md
git -C /abs/bus/spaces/core commit -m "Update the overlay"
git -C /abs/bus/spaces/core push origin HEAD:main
```

**The compatibility links.** The seven links keep the paths of the layout
before the split working for a node still on older product code, for one
change-over period. Nothing writes through them. `BUS_LAYOUT` stays `1` while
they last, and the later change that removes them bumps it (PROTOCOL §3.3).

**Repo names.** A repo is named by its scope (PROTOCOL §3.4):

| Repo | Name |
|---|---|
| the bus of a mesh | `agent-mesh-<mesh>` |
| another repo of one mesh | `agent-mesh-<mesh>-<role>`; scratch is `agent-mesh-<mesh>-tmp` |
| core | `<owner>-core` |
| personal lore | `<owner>-lore` |
| a project space | `<project>-space` |

The bus and scratch belong to this mesh. Core, lore and project spaces carry no
mesh name, so they travel without it. A project space may go to a
collaborator, who uses it with their own agents, with or without a mesh. Core
and lore stay yours: their records use the mesh profile, with agent ids,
hostnames and home paths, so they go to no collaborator, but they move with
you to any other mesh of yours. The split tool
prints the four names of your mesh and you:

```sh
/abs/agent-mesh/install/split-memory.sh names --owner <owner> --mesh <mesh>
```

```
bus agent-mesh-<mesh>
tmp agent-mesh-<mesh>-tmp
core <owner>-core
lore <owner>-lore
```

**Scratch rules.**

- One top-level folder per spike, named `[a-z0-9][a-z0-9._-]*`. Any agent of
  the mesh starts, saves or ends a spike through the `mesh-scratch` skill, with
  no librarian and no mesh task; a mesh task's executor writes none.
- A spike ends in one of three ways: filed (its content filed as a record in a
  space, which the outcome names), spawned (it started a project, which the
  outcome names), or abandoned. File the content first; then
  `spike.sh end` writes `<spike>.outcome.md`, and one commit removes the
  spike's folder and adds its outcome file.
- Scratch belongs to this mesh only: never hand its URL on, and never mount it
  in another mesh. A record in a shareable space, such as a project space,
  never cites scratch, and its librarian refuses one that does: file what the
  record needs as a record of its own, and cite that.
- Binary files go through Git LFS, as scratch's `.gitattributes` says; large
  data stays outside, by pointer, as in the bus.
- Scratch's history from before the split stays in the bus's own history.

## 11. Splitting memory into spaces

Once per mesh, a bus whose library and scratch are still in its own `memory/`
and `agent-tmp/` folders, the layout before the split, moves them into the
three spaces of section 10. Core and lore keep their history and their record
ids; scratch starts from its files at the bus's tip, without history.
`install/split-memory.sh` does the local work, and each step that reaches out
is yours: creating the repos, publishing to them, the bus commit and push.
`install/check-ready.sh` checks each node before and after.

Run both tools from a checkout of this product version, written `/abs/agent-mesh`
below: the bus's `product/` once its pin is at this version, or else a clone of
agent-mesh at it. The split tool needs bash 3.2 or later, git and Git LFS, and
for `split` git-filter-repo; it reads `templates/spaces/` beside it, so it runs
from a checkout. The readiness check is POSIX `sh`, needs only git and
`/usr/bin/python3`, and runs as a lone file too. Neither prints a credential:
each URL is shown without its user info.

**1. Before you start.** A node in developer mode (`MESH_PRODUCT_TRACK=tip`)
runs the tip of product `main`. Stop its poller (`/mesh-off`) before this
product version reaches `main`, since it expects a split bus. An adopter node
runs the bus's pin, which moves only at step 11.

**2. Create three empty private repos** on your git host, named by the naming
rule (section 10): `<owner>-core`, `<owner>-lore` and `agent-mesh-<mesh>-tmp`.
Leave them empty, with no README, license or branch: publish refuses a remote
that holds any ref. Making them first lets the readiness check prove that each
node reaches them.

**3. Readiness on every node.** On each node of the mesh, with the three new
URLs:

```sh
sh /abs/agent-mesh/install/check-ready.sh before --bus /abs/bus \
  --core-url <core url> --lore-url <lore url> --tmp-url <tmp url>
```

On the node that will run the split, add `--migrating`. `--env <class>` names
the node's environment class, by default `AGENT_CONTEXT` in its identity file;
the check knows only its own node, and reports are kept one per class. It is
read-only: it writes only in a temp folder it deletes, and its write probes are
`git push --dry-run` to a branch name the remote does not hold,
`refs/heads/check-ready-probe`. It prints one line per item, then a last line:

```
OK <class> <item> <detail>
MISSING <class> <item> <detail>: <operator step>
INFO <class> <item> <detail>
READY <class>                       last line; exit 0
NOT READY <class>: <n> missing      last line; exit 1
```

The items, in order: `git`; `git-lfs` (it runs, and the LFS filters are
configured); `filter-repo` (with `--migrating` only); `hook-python` (each hook
command's interpreter runs and is Python 3.9 or later); `read <url>` for the
bus's origin, each code submodule and the core, lore and scratch URLs;
`write <url>` for the bus and scratch on every node, and for core and lore on a
node whose `AGENT_ROLES` holds `librarian`; `gate <path> push` (the installed
git gate allows a push in `spaces/core`, `spaces/lore` and `spaces/tmp`);
`submodule <path>` (each code submodule at the bus's pin, with no change);
`leftovers` (no untracked or ignored file under `memory/` or `agent-tmp/`
before the split; on a `--migrating` node only an `INFO` count); `agent
swe-<role>` (the six SWE Pod role definitions resolve in the Claude Code
config); and `skill <name>` (the pod's skills and the mesh skills resolve,
`mesh-scratch` included). A project space's URL and any other product skill
get an `INFO` line, not counted. Each `MISSING` line ends with the step that
fixes it, such as "grant this node's git credential read access to `<repo>`;
a token limited to named repos needs `<repo>` added". Apply it and run the
check again, until the node prints `READY <class>`.

Save each node's whole output as `<class>.txt`, one file per class, in a
readiness folder on the node that runs the split, outside every repo and
outside the work folder of step 7, such as `/abs/split-readiness/`: the split
reads each class's report from that file name only. Start no later step
until every node's report ends in `READY <class>`.

**4. Leaving a node out.** The split needs a `READY` report for every
registered environment class, each distinct `context:` in the bus's
`agents/*.yaml`, and never leaves one out by default. To leave a registered
node out, on your own decision (say it is offline for the migration), name its
class with `--set-aside <class>` at step 7, once per class. The split then
prints `SET-ASIDE <class>: left out by the operator`, reads no report for that
class, and refuses with exit 3 a class no registered agent has
(`REFUSED set-aside <class>: not registered`) or this node's own class
(`REFUSED set-aside <class>: this node`). Keep the `SET-ASIDE` line with your
readiness reports. A set-aside node is not migrated: when it returns, it needs
`check-ready.sh before`, the change-over of step 12, its new remote if the bus
was renamed meanwhile (section 12), and `check-ready.sh after`, before its
poller starts again.

**5. Quiesce.** Let the librarian drain its queue, then stop the poller on
every node (`/mesh-off`). The library must have nothing uncommitted or
unpushed: the split refuses otherwise.

**6. Decide each scratch folder with untracked files.** The split carries into
scratch only the files tracked under `agent-tmp/` at the bus's `origin/main`
before the split. Decide, for each top-level folder there that holds
untracked, non-ignored files: keep it as a spike (`--keep <folder>`), leave it
out (`--leave <folder>`, then move its untracked files out of the bus before
step 10; its tracked files go to scratch with the split), or delete
it. For the ignored files inside spikes, decide whether mount carries them into
scratch (`--carry-ignored` at step 10) or you delete them.

**7. Split.** It only reads the bus: a read-only fetch, then a fresh clone of
the bus's origin inside the work folder.

```sh
/abs/agent-mesh/install/split-memory.sh split --bus /abs/bus \
  --work /abs/split-work --owner <owner> --mesh <mesh> \
  --readiness /abs/split-readiness [--set-aside <class>]... \
  [--keep <folder>]... [--leave <folder>]...
```

The work folder must be empty or absent, and outside the bus; keep it outside
every repo, as it holds a full copy of the library. The split runs five checks
in order, and at the first that fails prints its lines, makes nothing under
`--work` and exits:

| Check | Refusals | Exit |
|---|---|---|
| readiness | `REFUSED set-aside <class>: not registered` or `: this node`; `REFUSED readiness this node: no AGENT_CONTEXT`; `REFUSED readiness <class>: missing`, when the readiness folder holds no `<class>.txt`; `: not ready`, when that file exists but its last line that is not blank is not `READY <class>`, or, for this node's class, when it has no `OK <class> filter-repo` line; `: not a class name`, for a class that is not letters, digits, `.`, `_` and `-` starting with a letter or digit | 3 |
| library clean | `REFUSED fetch: no origin/main`; `REFUSED unclean memory/: <n> uncommitted, <m> unpushed`, for a staged, unstaged or untracked path under `memory/`, or a commit touching `memory/` or `agent-tmp/` that `origin/main` lacks, before the split | 4 |
| mapped | `UNMAPPED <path>`, for a file under `memory/` before the split outside the five categories and `memory/best-practices.user.md`, or a `.gitattributes`, `.gitignore` or `space.yaml` at the top of `agent-tmp/`, which scratch's own root files would replace | 4 |
| decided | `UNDECIDED agent-tmp/<folder>` for a folder of step 6 that no `--keep` or `--leave` names, before the split; `REFUSED keep agent-tmp/<folder>:` with `not a spike name`, `also left`, `no untracked file` or `holds a git repo` | 4 |
| tools | `REFUSED tool <name>`, for git, git-lfs or git-filter-repo | 3 |

A usage error, or a work folder that is not empty or not outside the bus,
exits 2. A git step that fails exits 1, with `ERROR <step>` and the last lines
of its log on stderr, user info removed; the work folder is left as it is, so
empty it before you run the split again.

Then it makes `<work>/core`, `<work>/lore` and `<work>/tmp`, each a repo on
`main` with no remote:

- core and lore: history filtered by path with git-filter-repo, the leading
  `memory/` dropped. Core keeps `notes/`, `refs/`, `runs/`, `workflows/` and
  `best-practices.user.md`; lore keeps `lore/`; each also keeps `.gitattributes`
  and `.gitignore`. Then the LFS objects each history references, fetched from
  the bus's origin.
- tmp: no history. Its first commit, `Start scratch from agent-tmp/ at bus
  <sha7>`, holds the files under `agent-tmp/` at the bus's `origin/main`
  before the split, the prefix dropped, and that tip's `.gitattributes` and
  `.gitignore`. Only the LFS objects that tip references are fetched.
- One commit per space adds `space.yaml` from the product's templates; tmp
  also gets the template `README.md` when it has none.
- For each `--keep <folder>`, one more commit in tmp, `Add spike <folder>,
  untracked before the split`, with that folder's untracked, non-ignored
  files.

It prints, and exits 0:

```
SET-ASIDE <class>: left out by the operator           one per --set-aside
SPLIT core history <c> commits, <f> files, <o> LFS objects
SPLIT lore history <c> commits, <f> files, <o> LFS objects
SPLIT tmp tip <sha7> <c> commits, <f> files, <o> LFS objects
VERIFY core ids <n> match
VERIFY lore ids <n> match
VERIFY tmp files <n> match
VERIFY core lfs <o> present
VERIFY lore lfs <o> present
VERIFY tmp lfs <o> present
```

`<c>` counts the commits on the space's `main`, so tmp's is 2 plus one per
`--keep`, and `<sha7>` is the bus tip scratch came from. `ids match`: the
record ids at core's and lore's tip are the ids under their old paths at
`origin/main`. `files match`: tmp's files, less `space.yaml`, a template
`README.md` and the kept files, are the files under `agent-tmp/` at
`origin/main` before the split, with the same content. `lfs present`: every
LFS object the space's history references is in its local store, and its
content's sha256 is its oid. A failure prints
`VERIFY <space> <ids|files|lfs> MISMATCH <n>` and exits 5: publish nothing,
and find the cause first. Most of the time goes to the LFS download, minutes
for a library of a few hundred MB. A record's history is in core's, for
example `git -C /abs/split-work/core log --oneline -- notes/<id>-<slug>.md`.

**8. Publish**, on your word, to the three empty repos:

```sh
/abs/agent-mesh/install/split-memory.sh publish --work /abs/split-work \
  --core-url <core url> --lore-url <lore url> --tmp-url <tmp url>
```

It first reads all three remotes, and pushes nothing at all when any of them
is refused, with exit 4: `REFUSED publish <space>: <url> unreachable` (check
the URL and this node's credential) or
`REFUSED publish <space>: remote not empty` (it holds a ref; give it an empty
repo). Then, per space, it pushes the LFS objects first and `main` second,
never with force, confirms with `git ls-remote` that the remote `main` is the
local one, and prints `PUBLISHED <space> <url> <sha7>, <o> LFS objects`. For
tmp that is only its tip's and the kept folders' objects. Check one: a fresh
clone of core, with Git LFS, has the bytes of a stored ref (its sha256 matches
the one in the bus), and a fresh clone of tmp has no LFS pointer file left in
its work tree.

**9. Clear the kept and left folders.** Scratch now holds each `--keep`
folder's untracked files, but the bus's `agent-tmp/<folder>`, still the folder
of the layout before the split, holds them too, and mount refuses each one as
`LEFTOVER`. Compare the two, then remove the untracked files from the bus:

```sh
# agent-tmp/ is the bus's scratch folder from before the split
diff -r /abs/bus/agent-tmp/<folder> /abs/split-work/tmp/<folder>
git -C /abs/bus clean -n -- agent-tmp/<folder>
git -C /abs/bus clean -f -- agent-tmp/<folder>
```

`diff` should show only the folder's ignored files, which `--carry-ignored`
carries or you delete. `clean -n` lists the files that `clean -f` removes: the
untracked, non-ignored files, the same the keep commit copied. Remove nothing
tracked by hand: mount removes the tracked files itself, and refuses a tracked
file you changed or deleted. Move each `--leave` folder's untracked files out
of the bus, and leave its tracked files: the split carried them into scratch,
and mount removes them from the bus.

**10. Mount**, in the bus clone. It commits nothing.

```sh
/abs/agent-mesh/install/split-memory.sh mount --bus /abs/bus \
  --core-url <core url> --lore-url <lore url> --tmp-url <tmp url> \
  [--carry-ignored]
```

Give each URL without user info, since it goes into `.gitmodules`; mount
refuses one with user info (exit 2). It refuses, with exit 4 and nothing
changed:

- `LEFTOVER <path>`, per untracked or ignored file under `memory/`, untracked
  file under `agent-tmp/`, ignored file under `agent-tmp/` without
  `--carry-ignored`, and tracked file changed or deleted under either, all in
  the folders of the layout before the split. Move the file out of the bus, or
  restore it.
- `REFUSED mount: <url> has no main`: publish that space first.
- `UNSPLIT <path>`, per tracked file under the bus's `memory/` or `agent-tmp/`,
  before the split, that its space's `main` lacks with the same content at the
  same path: a record that landed after the split. Add it to that space's
  `main` with the same content, or start again with fresh, empty repos.

Otherwise it removes the tracked files under `memory/` and `agent-tmp/`; adds
the three spaces as submodules (`branch = main`, `ignore = all`), each left on
its `main` branch; with `--carry-ignored`, moves each ignored file under
`agent-tmp/` to the same path under `spaces/tmp/`; writes the seven
compatibility links; appends the three `spaces.yaml` entries; sets the overlay
import in `guidance/CLAUDE.md`; and stages all of it. Adding the submodules
downloads each space's LFS content again, as large as the split's. It prints,
and exits 0:

```
MOUNTED spaces/core <sha7>
MOUNTED spaces/lore <sha7>
MOUNTED spaces/tmp <sha7>
RUN git -C <bus> commit -m "Split memory into core, lore and scratch spaces"
RUN git -C <bus> push origin HEAD:main
```

Run again on a bus where the mount is staged, it prints the three `MOUNTED`
lines and changes nothing.

**11. Commit and push**, on your word. Review the staged change first
(`git -C /abs/bus diff --cached --stat --ignore-submodules=none`, since
`ignore = all` hides the gitlinks), then run the `RUN` commit line. Move the
product pin to this product version in a commit of its own, so adopter nodes
get the new product with the mount:

```sh
git -C /abs/bus update-index --cacheinfo 160000,<product sha>,product
git -C /abs/bus commit -m "Pin product at <sha7>"
```

Then run the `RUN` push line. Run no sync tool push of the bus until every
node has changed over.

**12. Each node's change-over.** At each other node, with its poller stopped:

1. Move every leftover under `memory/` and `agent-tmp/`, the folders of the
   layout before the split, out of the bus: the pull cannot replace a folder
   that still holds files with its compatibility link.
2. Pull the bus, then update the product and clone the three spaces (name any
   other code submodule this node uses too), then check out `main` in each
   space, since `submodule update` leaves it detached:

   ```sh
   git -C /abs/bus pull
   git -C /abs/bus submodule update --init -- product \
     spaces/core spaces/lore spaces/tmp
   git -C /abs/bus/spaces/core checkout main
   git -C /abs/bus/spaces/lore checkout main
   git -C /abs/bus/spaces/tmp checkout main
   ```

3. Rerun the skill link loop of `INSTALL.md` step 3, so `mesh-scratch`
   resolves.
4. Run `check-ready.sh after` until it prints `READY <class>`:

   ```sh
   sh /abs/bus/product/install/check-ready.sh after --bus /abs/bus
   ```

   Its items: `bus` (the bus's HEAD is the fetched `origin/main`, and
   `spaces.yaml` lists core, lore and tmp); `cloned spaces/<x>` (each space
   initialized, on `main`); `lfs spaces/<x>` (no LFS pointer file left in a
   space's work tree); `overlay` (the bus's `guidance/CLAUDE.md` import chain,
   and the Claude Code config's `CLAUDE.md` chain where it exists, reach
   `spaces/core/best-practices.user.md` and name no `memory/` path);
   `lore-catalog` (the config's SessionStart hooks print a catalog that names
   `spaces/lore/lore`); and the `agent` and `skill` items of `before`.
5. Start the poller again (`/mesh-on`).

On the node that ran the split, mount left the three spaces on `main` already:
update the product (`git -C /abs/bus submodule update --init -- product`), then
do steps 3 to 5. Last, update any path that your overlay or the bus's `skills/`
gives for the old library and scratch folders, and commit the overlay in core
by hand.

## 12. Renaming the bus

A bus made before the naming rule may carry another name. Rename it to
`agent-mesh-<mesh>` in this order:

1. **Rename on the host first.** Use the git host's own rename, which keeps the
   repo's history, access and settings, and redirects the old URL to the new
   one. Never create a repo under the old name afterwards: it would take over
   the old URL, end the redirect, and leave every node still on that URL
   talking to the wrong repo.
2. **Nodes keep working through the redirect.** Each node's pulls and pushes
   with its old URL still reach the bus. Check one pull per node before you go
   on.
3. **Then update every place that names the bus:**
   - each node's remote:
     `git -C /abs/bus remote set-url origin <new url>`;
   - an umbrella repo that carries the bus as a submodule: set the bus's `url`
     in its `.gitmodules`, run `git -C /abs/umbrella submodule sync`, and
     commit `.gitmodules` there;
   - every other setting that names it: a phone seat's `GH_BUS_REPO`
     (`mobile/`), the librarian-ingress Worker's `BUS_REPO`
     (`services/librarian-ingress/`), and your own notes, overlay and tools.
4. **A node's bus folder.** Its local folder name is the node's own, and
   renaming it is optional. For a node whose bus folder carries the old name
   and that you rename, with its poller stopped:
   1. Move the folder to its new name in the same parent folder.
   2. Set `REPO_PATH` in the node's `~/.agent-identity.env` to the new folder's
      literal absolute path, and replace the old folder's line in the config's
      `mesh-git-allowlist.txt` with the new path, as `INSTALL.md` steps 2b and
      4 write them.
   3. Re-point every link under the config's `hooks/`, `skills/` and `agents/`
      whose target is under the old folder to the same path under the new
      one, and update each hook command in its `settings.json` that names the
      old folder.
   4. Update any checkout beside the bus that reaches it by its folder name,
      such as an operator kit (a 0-kit) whose guidance imports name the bus
      folder: pull its version that names the new folder.
   5. Check that a search of the config and the identity file for the old
      folder's path finds nothing, and that `check-ready.sh before --bus` with
      the new folder prints `READY <class>`. Then start its poller again
      (`/mesh-on`); its registration takes the new folder.

The config here is the node's Claude Code config folder:
`$CLAUDE_CODE_CONFIG_DIR`, else `$CLAUDE_CONFIG_DIR`, else `~/.claude`.

## 13. Glossary

- **Bus** — your private bus git repo (`agent-mesh-<mesh>`, one per mesh,
  named for the mesh); the only channel nodes use to coordinate.
- **Role** — a named queue (`tasks/roles/<role>/`) and the unit of addressing. Any
  node may hold several; a role may be held by several nodes.
- **Claim (accept-as-claim)** — how competing holders of a role avoid double-running
  a task: the first to write an `accepted` status and push owns it; the others yield.
- **Product** — the shipped code, living in a `product/` git **submodule**
  pinned to a tagged commit of the `agent-mesh` product repo.
- **Submodule pin** — the exact product commit the bus points at. Bumping it in
  one bus commit rolls a product update out to the whole mesh.
- **Library** — durable shared knowledge in the core space (categories
  `notes`, `refs`, `workflows`, `runs`) and the personal lore space (`lore`),
  curated by the holder of the `librarian` role. `runs` is the durable audit
  trail of what executed.
- **Space** — a git repo of records mounted in the bus under `spaces/`: core,
  lore, scratch, or a project space (sections 8 and 10).
- **Scratch, spike** — the mesh's scratch space (`spaces/tmp`) and one
  top-level folder in it: agent work in progress, until it is filed, spawns a
  project or is abandoned.
- **Workflow** — an autonomous multi-step chain, recorded as `workflows/<id>.yaml`,
  driven by the node that originated it, resumable from its cursor. Its durable
  write-up, once finished, is curated into core's `workflows/` by the librarian.
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
