# agent-mesh (product)

The mesh **product**: the protocol, skills, git gate, env templates, guidance,
and installer that turn a machine into a coordination node for Claude agents on
hosts that cannot reach each other directly.

This repo is the reusable software. The runtime coordination state — the
append-only ledger nodes read and write, plus the shared library — lives in a
separate **bus** repo (`agent-mesh-bus-<mesh>`, one per mesh, named for the
mesh), where this product is linked in as a pinned `product/` submodule. A node
clones the bus, checks out the recorded product pin, and runs it. See
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
| Implementing or auditing behavior | [`spec/PROTOCOL.md`](spec/PROTOCOL.md) — the normative reference |
| Wondering where this sits in the multi-agent landscape | [`docs/positioning.md`](docs/positioning.md) |
| Migrating an old node after the product/data split | [`docs/reinstall-after-split.md`](docs/reinstall-after-split.md) |

## Getting started — pick your path

This repo is software, not a running mesh. You do not clone it to join a mesh;
you either **stand up your own mesh** (creating a private bus) or **join one
that already exists**.

**A. Standing up a new mesh (no bus yet — start here if you found this repo).**

1. Create an **empty, private** repo on your own Git host — this becomes *your*
   bus. Naming convention: `agent-mesh-bus-<mesh>`, named for the mesh it
   coordinates. Keep it private: it holds your runtime coordination state, your
   credential *names*, and your deployment-specific rules. The product stays
   public; your bus never should.
2. Clone this product repo and run the installer, pointing it at the public
   product URL and your new (empty) bus URL:

   ```sh
   git clone https://github.com/you/agent-mesh.git
   cd agent-mesh
   PRODUCT_URL=https://github.com/you/agent-mesh.git \
   BUS_URL=<your-empty-private-bus-url> \
   BUS_PATH="$HOME/agent-mesh-bus-mymesh" \
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

## Idle costs nothing

A node's poller does not poll with inference. It parks on a portable shell
scanner (`skills/mesh-on/mesh-scan-loop.sh`) that pulls, scans the node's
queues, and sleeps in a loop, exiting only when there is claimable work (or a
stop/upgrade signal). While parked the agent spends **zero inference tokens**,
and an idle node makes **zero commits** — token and repo traffic are
proportional to real work, not to node-count × poll-frequency × uptime.

## The library — what the mesh remembers

Durable knowledge lives on the bus under `memory/`, curated by the holder of
the `librarian` role. Five fixed categories (normative definition:
[`spec/PROTOCOL.md`](spec/PROTOCOL.md) §7):

| Category | Holds |
|---|---|
| `lore/` | Verified operational gotchas: symptom / cause / fix / scope. |
| `notes/` | Durable research and design knowledge: specs, designs, comparisons, plans, handoffs. |
| `refs/` | External references (papers, decks, images) — stored via LFS, or pointer-only. |
| `workflows/` | Curated write-ups of multi-node processes that ran. |
| `runs/` | Provenance: one compact record per result-bearing task. |

`runs/` is the mesh's **audit trail**. Task scratch (message, status, outbox
result) is swept by retention, but the run record — who ran what, when, on
which node, with what outcome and artifact pointers — survives it. Together
with git history (every state change is a commit by an identified writer), what
the mesh did is reconstructable after the fact.

Any node submits durable learning as a `library.submit` message into the
librarian's queue; the librarian validates it, assigns an id, and promotes it
into `memory/<category>/`. Records are small text — heavy payloads stay outside
the bus and are referenced by pointer.

## Customizing a deployment — the overlays

The product is generic; a deployment personalizes it **in the bus**, never by
editing product files. Two overlay points:

- **Guidance overlay.** The bus entry point `guidance/CLAUDE.md` composes the
  chain every node loads: the product's `best-practices.base.md`, then the
  bus's private `memory/best-practices.user.md` (this deployment's rules,
  layered on top), then the product's `agent-operating.md` and
  `permissions.md`. To change mesh-wide behavior, edit the user overlay in the
  bus — the base stays pristine and upgradable.
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
| `skills/` | The `mesh-on` / `mesh-off` / `mesh-post` / `mesh-check` / `mesh-ref` Claude skills; symlinked into `~/.claude/skills/` from `product/skills/`. |
| `hooks/` | `git-gate.py` (path-scoped git gate + blob rejection), its settings snippet, and the allowlist template. |
| `templates/` | `*.env.template` files copied to `$HOME` and filled in per node (never committed). |
| `guidance/` | `best-practices.base.md` (universal, self-contained), `agent-operating.md`, `permissions.md`, `operator-interface.md`, and a product-side `CLAUDE.md`. |
| `install/` | The installer that scaffolds a bus and links this product in. |
| `bus-skeleton/` | The empty, `.gitkeep`-tracked directory skeleton a fresh bus starts from. |
| `docs/` | Design + operator docs (the product/data split, operator manual, re-install guide). |

The coordination directories (`agents/`, `tasks/`, `status/`, `outbox/`,
`workflows/`, `_archive/`) and the library (`memory/` — the five categories
above, plus the deployment's `memory/best-practices.user.md` overlay) live at
the **bus** root, not here. The bus's own `guidance/CLAUDE.md` composes the
product base with the deployment's user overlay (see `spec/PROTOCOL.md` §4.4).

## Core invariants

- Single writer per path; merges are impossible by construction.
- Credentials referenced by name only; values never enter the bus.
- Large blobs never enter the bus; records reference them by pointer in
  `artifacts`. The git gate enforces this.
- Messages are self-contained and immutable.
- Conflicts are re-derived, never resolved textually.
- The product submodule is read-only on nodes; only the operator bumps the
  pin.
