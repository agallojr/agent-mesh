# agent-mesh (product)

The mesh **product**: the protocol, skills, git gate, env templates, guidance,
and installer that turn a machine into a coordination node for Claude agents on
hosts that cannot reach each other directly.

This repo is the reusable software. The runtime coordination state — the
append-only ledger nodes read and write — lives in a separate **bus** repo
(`agent-mesh-<mesh>`, one per mesh, named for the mesh), where this product is
linked in as a pinned `product/` submodule. The shared library and the agents'
scratch live in memory spaces the bus mounts, each its own repo: core at
`spaces/core`, personal lore at `spaces/lore` and scratch at `spaces/tmp`. A
node clones the bus and its spaces, checks out the recorded product pin, and
runs it. See
[`docs/product-data-split.md`](docs/product-data-split.md) for the rationale.

## What a turn looks like

An operator steers in plain language from any Claude session — a workstation or
a phone. Nodes do the work. Everything meets in the bus as plain git commits:

> "Post to role `build`: run the nightly export and put the result in the
> outbox."

```
tasks/roles/build/20260814T1502-0001-nightly-export.md   operator posts the task
status/20260814T1502-0001.json                           a node claims: accepted
status/20260814T1502-0001.json                           running -> done
outbox/60ad2c/20260814T1502-0001-result.md               the claimant's result
tasks/roles/librarian/...                                provenance (runs) record
```

The operator reads the status and result back after a `git pull`. No broker, no
server, no shared network — just files, single-writer paths, and git.

## The docs

| You are | Read |
|---|---|
| A **user** driving a running mesh (post work, read results — terminal first; phone also works) | [`docs/operator-manual.md`](docs/operator-manual.md) |
| An **admin** installing a node on an existing mesh | [`INSTALL.md`](INSTALL.md) |
| An **admin** standing up a brand-new mesh (scaffold a bus) | [`install/README.md`](install/README.md) |
| Running biased reviewer agents (lenses) over a result | [`lenses/README.md`](lenses/README.md) |
| Implementing or auditing behavior | [`spec/PROTOCOL.md`](spec/PROTOCOL.md) — the normative reference |
| Wondering where this sits in the multi-agent landscape | [`docs/positioning.md`](docs/positioning.md) |
| Migrating an old node after the product/data split | [`docs/reinstall-after-split.md`](docs/reinstall-after-split.md) |
| Splitting a bus's library into spaces, or renaming a bus | [`docs/operator-manual.md`](docs/operator-manual.md) §10 to §12 |

## Getting started — pick your path

This repo is software, not a running mesh. You do not clone it to join a mesh;
you either **stand up your own mesh** (creating a private bus) or **join one
that already exists**.

**A. Standing up a new mesh (no bus yet — start here if you found this repo).**

1. Create an **empty, private** repo on your own Git host — this becomes *your*
   bus. Naming convention: `agent-mesh-<mesh>`, named for the mesh it
   coordinates. Keep it private: it holds your runtime coordination state and
   your credential *names*. The product stays public; your bus never should.
   The bus's three spaces get private repos of their own, named by the same
   rule: `<owner>-core` (your library and your deployment-specific rules),
   `<owner>-lore` (your operational lore) and `agent-mesh-<mesh>-tmp` (the
   mesh's scratch). The installer prints the steps that make them from the
   product's space templates and mount them.
2. Clone this product repo and run the installer, pointing it at the public
   product URL and your new (empty) bus URL:

   ```sh
   git clone https://github.com/you/agent-mesh.git
   cd agent-mesh
   PRODUCT_URL=https://github.com/you/agent-mesh.git \
   BUS_URL=<your-empty-private-bus-url> \
   BUS_PATH="$HOME/agent-mesh-mymesh" \
   ./install/install.sh --product-tag v0.1.0
   ```

   The installer scaffolds the bus from `bus-skeleton/`, links this product in
   as the pinned `product/` submodule, writes the bus's `guidance/CLAUDE.md`,
   and wires the git gate + skills. It **prints** the bus's first
   `commit`/`push` for you to run — it never pushes on its own. Full detail:
   [`install/README.md`](install/README.md). This node is the first node
   of your mesh.

**B. Joining an existing mesh (a bus is already running).** Clone that bus and
install a node against it — see [`INSTALL.md`](INSTALL.md). You do not run the
installer or touch the product directly; the product arrives as the bus's
`product/` submodule.

## How it is delivered

The product reaches every node as a submodule of the bus, pinned to a recorded
commit, so all nodes on the same bus commit run byte-identical code. Nodes ride
the **recorded pin** (adopter mode, the default): a sync realizes the commit the
bus records, not product `main` tip. Shipping a mesh-wide update = bump the
submodule pin in one bus commit; nodes pick it up on their next `git pull` +
`git submodule update --init --recursive`. (Tracking `main` tip is developer mode,
opt-in per node via `MESH_PRODUCT_TRACK=tip` — for the maintainer's own mesh; see
[`INSTALL.md`](INSTALL.md).) The installer (`install/install.sh`) scaffolds a fresh
bus from `bus-skeleton/`, adds this product as the `product/` submodule at a chosen
pin, and wires the git gate and skill symlinks.

## Idle costs almost nothing

A node's poller does not poll with inference. It parks on a portable shell
scanner (`skills/mesh-on/mesh-scan-loop.sh`) that pulls, scans the node's
queues, and sleeps in a loop, exiting only when there is claimable work (or a
stop/upgrade signal). While parked the agent spends **zero inference tokens**.
An idle node's only commit is its heartbeat: each scan rewrites `last_poll` in
the node's own `agents/<id>.yaml` and pushes it, one small commit per poll
interval, so `mesh-check` can name a node that has stopped polling. Claims,
statuses and results stay proportional to real work.

Every commit the mesh tooling makes goes through `skills/mesh-on/mesh-commit.sh`,
which stages only the paths it is given and never records a submodule pin.

## The library — what the mesh remembers

Durable knowledge lives in two memory spaces the bus mounts, each its own
repo: **core** (`spaces/core`) and **personal lore** (`spaces/lore`), curated
by the holder of the `librarian` role, who files each record through the
`space-librarian` skill. Five fixed categories (normative definition:
[`spec/PROTOCOL.md`](spec/PROTOCOL.md) §7):

| Category | Space | Holds |
|---|---|---|
| `lore/` | lore | Verified operational gotchas: symptom / cause / fix / scope. |
| `notes/` | core | Durable research and design knowledge: specs, designs, comparisons, plans, handoffs. |
| `refs/` | core | External references (papers, decks, images) — stored via LFS, or pointer-only. |
| `workflows/` | core | Curated write-ups of multi-node processes that ran. |
| `runs/` | core | Provenance: one compact record per result-bearing task. |

`runs/` is the mesh's **audit trail**. Task scratch (message, status, outbox
result) is swept by retention, but the run record — who ran what, when, on
which node, with what outcome and artifact pointers — survives it. Together
with git history (every state change is a commit by an identified writer), what
the mesh did is reconstructable after the fact.

Any node submits durable learning as a `library.submit` message into the
librarian's queue; the librarian validates it, assigns an id, and files it in
its category folder in core or lore. Records are small text — heavy payloads
stay outside the bus and its spaces and are referenced by pointer.

**Scratch** (`spaces/tmp`) is not library. It is the mesh's own space for
agent work in progress, one folder per spike: any agent of the mesh writes it
through the `mesh-scratch` skill, with no librarian, and ending a spike records
whether it was filed into a space, spawned a project or was abandoned. Scratch
belongs to one mesh; core, lore and project spaces carry no mesh name, so they
can be handed on or used without the mesh.

## Project spaces

Core and lore are this mesh's own library. A bus may also mount other
**memory spaces**: separate git repos of records, each with its own owner,
visibility, writer and reference rules. A **project space** (`proj:<name>`)
holds everything a
project's participants need to continue the work. The operator mounts one by
hand, as a submodule under `spaces/` listed in `spaces.yaml`, and a node clones
it only when something first needs it. A session loads it with
`load <project>` (the `mesh-load` skill), and a task loads it for its executor
through the task's `project:` field (`mesh-post --project`). Each space has one
writer, its librarian: the `space-librarian` skill checks every record's
profile, references and id, then commits it and pushes it to the space's
`main`. Without a bus, a session runs the same skill as its own librarian. The
files a task returns in its result (`files:`) reach the space through that
librarian too. The design, and which parts this version implements, is in
[`spec/memory-spaces.md`](spec/memory-spaces.md). The protocol side is in
[`spec/PROTOCOL.md`](spec/PROTOCOL.md) §3 and §5, and how to mount a space is
in [`docs/operator-manual.md`](docs/operator-manual.md) §8.

The **SWE Pod**, a spec-driven process for software changes that keeps its
records in a project space, adds six roles: `swe.spec`, `swe.plan`,
`swe.lead`, `swe.build`, `swe.test` and `swe.review`. They are
per-task-output roles (PROTOCOL §2), so any number of nodes may hold each. A
node takes one by adding it to `AGENT_ROLES` in its identity file; the
protocol, the guidance and the poller treat them like any other role.

## Customizing a deployment — the overlays

The product is generic; a deployment personalizes it **in the bus**, never by
editing product files. Two overlay points:

- **Guidance overlay.** The bus entry point `guidance/CLAUDE.md` composes the
  chain every node loads: the product's `best-practices.base.md`, then the
  private overlay `spaces/core/best-practices.user.md` in core (this
  deployment's rules, layered on top), then the product's
  `agent-operating.md` and `permissions.md`. To change mesh-wide behavior,
  edit the user overlay in core and commit it there by hand — the base stays
  pristine and upgradable.
- **Skills overlay.** `<bus>/skills/` overrides product skills by name: the
  installer links product skills into `~/.claude/skills/` first, then bus
  entries, so a same-named bus skill wins on that node and a new name adds an
  instance-only skill. Prefer tuning behavior through the guidance overlay; a
  whole-skill copy is the escape hatch, not the first move.

## Security posture

- **The bus is private; the product is public.** The bus carries your ledger,
  credential names, and deployment rules — keep its repo private.
- **Credential values never enter the bus.** Values live only in each node's
  `~/.agent-credentials.env` (mode 600). Messages, statuses, logs, and results
  carry credential **names** only; a blocked task reports the name it needs,
  never a value.
- **Path-scoped git gate.** A PreToolUse hook (`hooks/git-gate.py`) permits
  `git add/commit/push` only on allowlisted repo paths, requires literal
  absolute paths it can verify, and fails closed. It also rejects staging
  large or binary blobs into the bus.
- **Single-writer by construction.** Each node writes only the paths it owns,
  so merges cannot happen and every change is attributable — git history is a
  tamper-evident log of who wrote what, when.
- **Authenticated email ingress** (optional, off by default): mail becomes a
  mesh message only if DKIM/DMARC pass with the domain aligned to `From`, the
  verified sender is on an exact-match allowlist, AND a shared-secret body
  line matches under a constant-time compare. The allowlist alone is never
  authorization.

## Layout (product repo)

| Path | Role |
|---|---|
| `spec/` | The protocol definition (`PROTOCOL.md`) — the normative reference. |
| `skills/` | The `mesh-on` / `mesh-off` / `mesh-post` / `mesh-check` / `mesh-ref` / `mesh-load` / `mesh-scratch` / `space-librarian` Claude skills; symlinked into `~/.claude/skills/` from `product/skills/`. |
| `hooks/` | `git-gate.py` (path-scoped git gate + blob rejection), its settings snippet, and the allowlist template. |
| `templates/` | `*.env.template` files copied to `$HOME` and filled in per node (never committed), and `templates/spaces/`, the core, lore and scratch space templates. |
| `guidance/` | `best-practices.base.md` (universal, self-contained), `agent-operating.md`, `permissions.md`, `operator-interface.md`, and a product-side `CLAUDE.md`. |
| `install/` | The installer that scaffolds a bus and links this product in; `split-memory.sh`, which splits a bus's library into its spaces; and `check-ready.sh`, a node's read-only readiness check. |
| `bus-skeleton/` | The empty, `.gitkeep`-tracked directory skeleton a fresh bus starts from. |
| `docs/` | Design + operator docs (the product/data split, operator manual, re-install guide). |

The coordination directories (`agents/`, `tasks/`, `status/`, `outbox/`,
`workflows/`, `_archive/`) live at the **bus** root, not here, and the bus
mounts the spaces under `spaces/`: core (`spaces/core`, the four core
categories above plus the deployment's `best-practices.user.md` overlay),
personal lore (`spaces/lore`) and scratch (`spaces/tmp`). For one change-over
period the bus also keeps seven compatibility links at the library and scratch
paths of the layout before the split (`spec/PROTOCOL.md` §3.5). The bus's own
`guidance/CLAUDE.md` composes the product base with the deployment's user
overlay (see `spec/PROTOCOL.md` §4.4).

## Core invariants

- Single writer per path; merges are impossible by construction.
- Credentials referenced by name only; values never enter the bus.
- Large blobs never enter the bus; records reference them by pointer in
  `artifacts`. The git gate enforces this.
- Messages are self-contained and immutable.
- Conflicts are re-derived, never resolved textually.
- The product submodule is read-only on nodes; only the operator bumps the
  pin.
