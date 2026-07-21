# agent-mesh (product)

The mesh **product**: the protocol, skills, git gate, env templates, guidance,
and installer that turn a machine into a coordination node for Claude agents on
hosts that cannot reach each other directly.

This repo is the reusable software. The runtime coordination state — the
append-only ledger nodes read and write, plus the shared library — lives in a
separate **bus** repo (`agent-mesh-bus`), where this product is linked in as a
pinned `product/` submodule. A node clones the bus, checks out the pinned
product, and runs it. See
[`docs/product-data-split.md`](docs/product-data-split.md) for the rationale.

- Full protocol: [`spec/PROTOCOL.md`](spec/PROTOCOL.md)
- Fresh node install: [`INSTALL.md`](INSTALL.md)
- Existing node migrating after the split: [`docs/reinstall-after-split.md`](docs/reinstall-after-split.md)
- Driving the mesh from a phone: [`docs/operator-manual.md`](docs/operator-manual.md)
- Scaffolding a new bus: [`install/`](install/)

## How it is delivered

The product reaches every node as a submodule of the bus, pinned to a tagged
commit, so all nodes on the same bus commit run byte-identical code. Shipping a
mesh-wide update = bump the submodule pin in one bus commit; nodes pick it up on
their next `git pull` + `git submodule update --init --recursive`. The installer
(`install/install.sh`) scaffolds a fresh bus from `bus-skeleton/`, adds this
product as the `product/` submodule at a chosen tag, and wires the git gate and
skill symlinks.

## Layout (product repo)

| Path | Role |
|---|---|
| `spec/` | The protocol definition (`PROTOCOL.md`) — the normative reference. |
| `skills/` | The `mesh-on` / `mesh-off` Claude skills; symlinked into `~/.claude/skills/` from `product/skills/`. |
| `hooks/` | `git-gate.py` (path-scoped git gate + blob rejection), its settings snippet, and the allowlist template. |
| `templates/` | `*.env.template` files copied to `$HOME` and filled in per node (never committed). |
| `guidance/` | `best-practices.base.md` (universal, self-contained), `agent-operating.md`, `permissions.md`, `operator-interface.md`, and a product-side `CLAUDE.md`. |
| `install/` | The installer that scaffolds a bus and links this product in. |
| `bus-skeleton/` | The empty, `.gitkeep`-tracked directory skeleton a fresh bus starts from. |
| `docs/` | Design + operator docs (the product/data split, operator manual, re-install guide). |

The coordination directories (`agents/`, `tasks/`, `status/`, `outbox/`,
`mailbox/`, `workflows/`, `_archive/`) and the library (`memory/lore/`,
`memory/experiments/`, `memory/best-practices.user.md`) live at the **bus** root,
not here. The bus's own `guidance/CLAUDE.md` composes the product base with the
deployment's user overlay (see `spec/PROTOCOL.md` §4.4).

## Core invariants

- Single writer per path; merges are impossible by construction.
- Credentials referenced by name only; values never enter the bus.
- Large blobs never enter the bus; records reference them by pointer in
  `artifacts`. The git gate enforces this.
- Messages are self-contained and immutable.
- Conflicts are re-derived, never resolved textually.
- The product submodule is read-only on nodes; only the hub/operator bumps the
  pin.
