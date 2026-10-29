# Architecture — the three planes

The mesh is built from three planes. Each has one owner, one repo or machine,
and one upgrade path. Everything in the system lives in exactly one of them.

| Plane | Form | Visibility | Owner / writer |
|---|---|---|---|
| **Product** | git repo (`agent-mesh`) | public | the product maintainers |
| **Bus** (instance) | git repo (`agent-mesh-<mesh>`), mounting its memory spaces | private, one per mesh | the operator + that mesh's nodes |
| **Node** | a machine's local install | local only, never in git | that machine's operator |

## 1. Product — the software

The product repo is public and contains no operator content: no operator
names, paths, credentials, or deployment specifics anywhere in it.

- `spec/PROTOCOL.md` — the contract that gives bus data meaning: message
  schemas, status lifecycle, library categories, retention. The spec also
  covers the enforcement code that implements it.
- `guidance/` — base agent guidance (best-practices.base, agent-operating,
  permissions, operator-interface).
- `skills/` — base skills (mesh-on, mesh-off, mesh-post, mesh-check, ...).
- `hooks/` — enforcement code that runs on nodes (git-gate, settings
  snippet, allowlist template).
- `templates/` — node identity / credentials templates, and the core, lore
  and scratch space templates (`templates/spaces/`).
- `bus-skeleton/` — the executable form of "how to instantiate a bus": a
  complete, working bus layout. Instantiation = copy skeleton + pin product.
- `install/` — the installer that scaffolds a bus from the skeleton and
  wires a node; `split-memory.sh`, which splits a bus's library and scratch
  into spaces; and `check-ready.sh`, a node's read-only readiness check.
- `upgrades/` — one note per bus-layout transition (see §4). Upgrade notes
  are written to be executed by an agent, and include any node-side steps.
- `spec/LAYOUT_VERSION` — the bus layout this product version expects.

## 2. Bus — one user mesh's instance

The bus is private. One bus per user mesh, named for it: `agent-mesh-<mesh>`.
It contains the deployment's coordination state, its mesh configuration and its
deviations from the product defaults — nothing executable beyond what it
overrides — and mounts the memory spaces that hold its knowledge, each its own
repo and its own git submodule. It stores only a pointer to each space, never
its contents.

- **KB** — the core and personal lore spaces, at `spaces/core` (repo
  `<owner>-core`: `notes/ refs/ workflows/ runs/`) and `spaces/lore` (repo
  `<owner>-lore`: `lore/`) — the durable library, librarian-curated, plus the
  operator-authored guidance overlay `spaces/core/best-practices.user.md`.
  Writer split: the librarian role files the records into core and lore
  through `space-librarian`, in each space's own repo; the operator owns the
  overlay and commits it in core by hand.
- **Scratch** — `spaces/tmp` (repo `agent-mesh-<mesh>-tmp`) — the agents'
  work in progress, one folder per spike, written by any agent of this mesh
  with no librarian. Not library, and it belongs to this mesh only.
- **Other spaces** — project spaces under `spaces/`, mounted by the operator
  and loaded on demand.
- **MQ** — `agents/ tasks/ status/ outbox/ workflows/ _archive/` — live
  coordination state. Ephemeral, swept by the archiver, never pinned upward.
- **Overrides** — the guidance overlay in core and `skills/` at the bus root
  (instance skill overlays; a bus skill with the same name as a product skill
  wins). Prefer skills that read tunables from the guidance overlay;
  whole-skill override is the escape hatch. Instance skill descriptions say
  when to invoke — never standing directives.
- **Compatibility links** — for one change-over period, `memory/lore`,
  `memory/notes`, `memory/refs`, `memory/runs`, `memory/workflows`,
  `memory/best-practices.user.md` and `agent-tmp` link into the spaces, so a
  node on older product code finds the paths of the layout before the split.
- **Composer** — `guidance/CLAUDE.md` — the entry point that layers product
  base guidance under the instance overlay. The bus owns composition.
- **Version stamp** — `BUS_LAYOUT` at the bus root: a single integer naming
  the layout this bus conforms to (see §4).
- **The pin** — `product/` submodule + `.gitmodules`. The bus records
  exactly which product commit its state was written against. Nodes ride
  the recorded pin; only the operator (or an upgrade) advances it. A space's
  gitlink is different: nodes follow the space's tip, and the gitlink moves
  only as a checkpoint.

**Names.** A repo is named by its scope: one that belongs to one mesh carries
the mesh's name (the bus `agent-mesh-<mesh>`, its other repos
`agent-mesh-<mesh>-<role>`, scratch `agent-mesh-<mesh>-tmp`); a portable
space's repo carries none (`<owner>-core`, `<owner>-lore`, `<project>-space`),
so the space can be handed to a collaborator, or mounted by another mesh,
unchanged (`spec/PROTOCOL.md` §3.4).

## 3. Node — one machine

A node is a machine joined to a bus. Its state is local, per-machine, and
never committed anywhere:

- `~/.agent-identity.env` — AGENT_ID, roles, REPO_PATH.
- `~/.agent-credentials.env` — secret values. Credentials exist only on
  nodes; the planes above carry credential *names* only. This is a designed
  property, not a convention.
- `~/.claude` wiring — settings, the git-gate hook, the allowlist, and the
  skill links. Hooks and skills are **symlinked** into the bus's `product/`
  submodule (and the bus `skills/` overlay), so they upgrade when the pin
  advances — nothing installed by copy that can go silently stale.

A node install and a node upgrade are both defined by the product
(`INSTALL.md`, `upgrades/`); a bus upgrade note carries a node section when
node wiring must change.

## 4. Versioning and upgrades — the user is unaware

The versioned thing is the **bus layout**: the directory shapes and file
contracts the product code assumes. Not marketing versions, not commits.

- The bus states what it is: `BUS_LAYOUT` (integer).
- The product states what it expects: `spec/LAYOUT_VERSION` (integer).
- The product documents every transition: `upgrades/to-<N>.md`, written for
  an agent to execute idempotently, covering bus changes and any node steps.

The upgrade is agent-driven and invisible to the user. On every sync (the
mesh-on poller, or any agent pulling the bus), after `git pull` +
`submodule update`:

1. Compare bus `BUS_LAYOUT` to product `spec/LAYOUT_VERSION`.
2. Equal — proceed normally (the common case, zero cost).
3. Bus behind — apply `upgrades/to-<bus+1>.md` … in order, stamping
   `BUS_LAYOUT` after each, then proceed. The agent does what the note says.
4. Bus ahead — this product checkout is too old for this bus. Stop and
   report; never guess forward.

Because nodes ride the recorded pin, an upgrade reaches a node only when
the operator (or the upgrade flow itself) advances the pin — one bad push
to product `main` cannot break a fleet.

**Pin semantics.** Adopter mode (default): `submodule update` *without*
`--remote`; nodes run exactly the product commit the bus records.
Developer mode (the product maintainer's own mesh): the maintainer may
track product tip locally, and their chained-pin tooling advances the
recorded pin at every checkpoint. The two modes differ only in how often
the pin moves.

## 5. Composition — how overrides work

One pattern, used twice:

- **Guidance**: `bus/guidance/CLAUDE.md` imports product base files, then
  the overlay in core (`@../spaces/core/best-practices.user.md`). Later
  layers override earlier ones. The product defines the base; the bus owns
  the composition order.
- **Skills**: the installer links product skills into `~/.claude/skills/`
  first, then bus `skills/` entries — same name, bus wins. The product
  defines the defaults; the bus supplies the deviations.

## 6. Non-goals — the boundary, stated

- The product contains **no operator content**. If a file names a user, a
  path on someone's machine, or a deployment's remote, it does not belong
  in the product.
- The bus contains **no personal-notebook content**. An operator's research
  notebook is out of scope for the mesh entirely; the KB holds the
  mesh-facing digest of knowledge, not the operator's thinking. Test: if an
  agent on another node needs it to act, it is a KB record; otherwise it
  stays in the notebook.
- Nothing in the product or a bus references upward into whatever repo may
  contain them. A bus is complete standing alone.
- Credentials never appear in any plane but the node, and there only in
  `~/.agent-credentials.env`.

## 7. Federation — considered, not implemented

The case: one user, two meshes forced by network boundaries — an internal
bus reachable only inside a company network, an external bus on the open
network. A company server node mounts only the internal bus; an external
node mounts only the external bus; the user's laptop can reach both.

Direction, if built:

- **A node may mount several buses.** Identity grows a per-bus section
  (REPO_PATH, roles per bus); the poller scans each mounted bus
  independently. Nothing in bus layout changes — federation is a node
  capability, not a bus one.
- **Buses never talk to each other.** No cross-bus git relationship, no
  shared remotes. The only connection is a **bridge node** that mounts
  both and forwards messages explicitly, under an operator-written policy.
  Message forwarding is re-posting (new message, provenance noted), not
  mirroring.
- **Unified KB is a read-side view.** A node that mounts both buses
  searches both libraries; every record keeps exactly one home space, and
  single-writer discipline is per-space and untouched. Durable sharing is a
  librarian-mediated export: a record is *submitted* to the other bus's
  librarian queue, filtered at the bridge.
- **The trust boundary is directional.** Internal → external crossings are
  the dangerous ones; the bridge policy names what may cross outward
  (default: nothing). External → internal is a normal untrusted ingress,
  like email. The internal bus's existence is never referenced from the
  external bus.

Not designed further until there is a concrete second mesh.
