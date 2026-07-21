# Agent Mesh — Separating the Product from the Data

**Design document · draft v4 · 2026-07-20**

> **Changes since v3.** Composition of best-practices now lives in the **bus**,
> not in the product (the product artifact is fully self-contained — §6). The
> contaminated `best-practices.md` is **not** filtered into product history at
> all; a fresh base file is authored instead (§7). Naming is settled: **product
> = `agent-mesh`, bus = `agent-mesh-bus`** (§4, §10). Blob enforcement moves from
> `.gitignore` alone to the **git-gate hook** (§5). The poller does an explicit
> `submodule update` rather than trusting `--recurse-submodules` (§7, §9). The
> `product/` gitlink is added to the ownership matrix (§9). `VERSION` is dropped
> in favor of deriving the tag from the pin (§4). The `@`-include mechanism is
> pinned to Claude Code's native recursive import (§2, §6). The one-pull property
> is stated honestly as *one-pull-if-recursion-is-realized* (§1, §8).

## 1. Problem

`agent-mesh` is a single Git repo doing three different jobs at once:

1. **Product code** — the mesh protocol, the `mesh-on`/`mesh-off` skills, the
   git-gate hook, env templates, the operating/permission guidance, and (new) an
   installer. Reusable, versionable software.
2. **The coordination bus** — `agents/ tasks/ status/ outbox/ mailbox/ workflows/
   _archive/` plus the **library** (`memory/`: lore + experiment logs). Per-
   deployment runtime state: the append-only ledger nodes read/write, and the
   shared knowledge store. It must stay a single writable Git repo (the bus *is*
   Git), and it is what every node pulls.
3. **Large result blobs** — heavy binary payloads (fields, checkpoints, images)
   that belong in neither of the above. **How and where these are stored is out of
   scope for the mesh** — it is user/workflow/experiment-specific. The mesh's only
   responsibility is to keep them *out* of the bus and reference them by pointer.

Mixing the first two means the product can't be versioned/reviewed/published
without dragging along private state; letting the third in bloats every clone.

### The load-bearing property

The design ships shared material *inside* the bus so **every node gets the latest
from one `git pull`** — byte-identical protocol/guidance/skills, and the latest
lore and experiment logs. Nodes consume the product at fixed paths
(`${REPO_PATH}/product/spec/…`, `${REPO_PATH}/product/guidance/…`, skills
symlinked from `product/skills/`). Any split must keep that one-pull property
true.

**One honest caveat.** In-repo/vendored content gets this property *for free* — a
plain `pull` updates it. Delivering the product as a **submodule** (the chosen
design, §8) makes it *one-pull-if-recursion-is-realized*: the pull must be
followed by a submodule checkout to the pinned commit. We keep the property true
by baking that step into the poller (§7 step 5, §9) rather than trusting a client
flag. This is the one place the submodule choice is weaker than vendoring, and we
accept it in exchange for a clean product/bus boundary.

## 2. Terminology (so we stop colliding on words)

| Term | Means | Where it lives |
|---|---|---|
| **product** / **code** | the mesh software: protocol, skills, hooks, templates, guidance, installer | its own repo (`agent-mesh`), **private for now → public once tested** |
| **bus** | the coordination repo nodes pull & push | private repo (`agent-mesh-bus`) |
| **library** | the record store: **lore + experiment logs + the user best-practices** (`memory/`) | inside the **bus** |
| **blob store** | large binary results, referenced by pointer | **outside the mesh; user/workflow-specific — the mesh does not define or assume it** |

"Library" = the knowledge/record store, **not** the code. The code is "product."

**Include mechanism.** Wherever this doc writes `@path`, it means **Claude Code's
native recursive `@`-import** — the same mechanism `guidance/CLAUDE.md` already
uses today (`@best-practices.md`, `@agent-operating.md`, `@permissions.md`). It is
resolved by Claude when it reads the entry-point file, relative to that file's
directory, and is depth-limited by the harness. We deliberately do **not**
introduce a second, agent-driven "read the chain yourself" mechanism — one
composition path, one set of resolution semantics.

## 3. Current inventory (classified)

| Path | Class | Disposition |
|---|---|---|
| `spec/PROTOCOL.md` | Product | → product repo |
| `skills/mesh-on`, `skills/mesh-off` | Product | → product repo |
| `hooks/git-gate.py` (+ snippet, allowlist template) | Product | → product repo |
| `templates/*.env.template` | Product | → product repo |
| `guidance/CLAUDE.md`, `agent-operating.md`, `permissions.md`, `operator-interface.md` | Product | → product repo |
| `guidance/best-practices.md` | **Mixed / contaminated** | **Not filtered into product history.** Author a fresh `guidance/best-practices.base.md` (universal rules only, no history) in the product. The personal half (q8020, `~/proj/src`, 0-kit, sweep policy) is born new in the bus library as `memory/best-practices.user.md`. See §6, §7. |
| `README.md`, `INSTALL.md`, `.gitignore`, `.gitattributes` | Product | → product repo (bus keeps its own thin `.gitignore`) |
| `agents/`, `tasks/`, `status/`, `outbox/`, `mailbox/`, `workflows/`, `_archive/` | Bus runtime | Stay in the bus |
| `memory/lore/` | Library | Stay in the bus |
| `memory/experiments/` (the logs) | Library | Stay in the bus |
| (future) large binary results | Blob | Not in the bus; pointer only |

## 4. Target architecture — two repos we build, one boundary we enforce

```
agent-mesh            PRODUCT repo — the software. Private now; flip to public once tested.
  spec/ skills/ hooks/ templates/ guidance/(sanitized) README INSTALL
  guidance/best-practices.base.md   universal rules only, self-contained (no reaching @-include)
  install/            the installer: scaffolds a fresh bus and links the product in
  bus-skeleton/       dir skeleton for initializing a bus (dirs carry .gitkeep placeholders)

agent-mesh-bus        BUS repo — private; the repo every node clones, pulls, pushes.
                      (This is the CURRENT repo, renamed from agent-mesh — see §7 step 2.)
  product/   ->  git submodule, pinned to an agent-mesh tag   (the product "linked in")
  agents/ tasks/ status/ outbox/ mailbox/ workflows/ _archive/
  memory/             THE LIBRARY (text only):
    lore/                shared, hub-curated
    experiments/         experiment logs
    best-practices.user.md   this operator's env-specific rules (composed by the bus, §6)
  guidance/CLAUDE.md  bus entry point: @-includes product/guidance/best-practices.base.md
                      AND memory/best-practices.user.md (the bus owns composition)
  .gitmodules, .gitignore (first-line blob filter; real enforcement is the git gate, §5)
```

The bus no longer needs a `VERSION` file: the submodule already pins an exact
product commit, so the pin *is* the source of truth. A human-readable tag is
derived on demand with `git -C product describe --tags` — no second copy to drift.

**Product delivery = the product repo linked into the bus as a pinned submodule.**
This is the "installation creates a bus with the product linked in" model. A node
clones the bus and checks out the pinned product commit, so every node on the same
bus commit runs byte-identical product code — no drift, no separate install to
keep in sync. Product paths shift by a fixed prefix
(`${REPO_PATH}/product/spec/…`), a mechanical repoint of the skill and guidance
references. Shipping a product update mesh-wide = bump the submodule pointer in one
bus commit; nodes pick it up on their next pull + submodule update. The
**installer** (part of the product) scaffolds a fresh bus from `bus-skeleton/`,
adds the product submodule at a chosen tag, and wires the git gate / symlinks. (A
private submodule works fine while both repos are private; when the product flips
public, the bus stays private and simply references a now-public submodule — no
bus change.)

**The library stays in the bus.** `memory/` (lore + experiment logs) is written at
runtime (the hub curates lore; the centralize-log workflow writes experiment logs)
and is meant to be read by every node — so a plain `git pull` of the bus delivers
the latest lore and logs to everyone. It is deliberately *not* in the product
submodule (read-only, pinned) and *not* a separate repo (which would break
one-pull propagation).

**Blobs are handled outside the mesh.** Large binary payloads never enter the bus.
Where they go — a git-LFS repo, an S3 bucket, a scratch filesystem, nothing at all
— is a per-user, per-workflow, per-experiment choice the mesh neither defines nor
assumes. The mesh's contribution is exactly two things: (1) keep blobs out of the
bus, and (2) let a record reference a blob by **pointer** using the protocol's
existing `artifacts` field (pointers, not payloads). That's the whole contract.

## 5. Keeping blobs out of the bus (enforced at the gate, filtered at .gitignore)

The mesh doesn't say where blobs live, only that they don't live in the bus. Two
layers, distinct in strength:

- **First-line filter — bus `.gitignore`.** Blocks binary/large extensions from a
  wildcard add: `*.nc *.h5 *.hdf5 *.ckpt *.npy *.npz *.png *.jpg *.mp4 *.tar
  *.zip` (tune to taste). This is a *convenience* guard: it stops accidental
  `git add .`, but `git add -f`, an unlisted extension, or an oversized text file
  walk right past it. It is **not** the enforcement boundary.
- **Real enforcement — the git gate.** `hooks/git-gate.py` already parses `add`
  invocations to gate them by target repo. Extend it to also **reject staging of
  blob-class files** (blocked extensions, and files over a size threshold) into
  the bus. Because the gate reads the command before the shell runs it and is
  fail-closed, this survives `git add -f` and catches paths `.gitignore` never
  listed. This is the single *enforced* boundary; `.gitignore` is the ergonomic
  first line in front of it.
- **Pointers, not payloads** — already in the protocol: a record's `artifacts`
  field carries a reference (path/URL/oid) to a blob; the payload itself lives in
  whatever store the workflow chose. No new blob-store schema to define.

## 6. Best-practices: product ships a self-contained base; the bus composes in the user overlay

`guidance/best-practices.md` today blends universal agent rules (code style,
autonomy, git literal-path discipline, PEP 8) with this operator's private
environment (q8020, `~/proj/src`/0-kit config policy, sweep-run rules). Those are
two different things with two different homes. The key design decision in v4:
**the product artifact is self-contained, and the *bus* owns the composition** —
the product never reaches up out of itself.

- **General base ships with the product, self-contained** — `product/guidance/
  best-practices.base.md`, universal rules only, alongside `agent-operating.md`,
  `permissions.md`, `operator-interface.md`. It contains **no reaching
  `@`-include** — a standalone or public checkout of the product resolves
  completely on its own, with nothing pointing outside the repo. Safe to make
  public.
- **User overlay lives in the bus library** — `memory/best-practices.user.md`,
  the operator's environment-specific rules. Per-deployment, private, and (like
  lore) propagates to every node by a plain `git pull` of the bus.
- **The bus composes the two, not the product.** The bus's well-known entry point
  `guidance/CLAUDE.md` `@`-includes **both** the product base and the user
  overlay:

  ```
  @product/guidance/best-practices.base.md
  @memory/best-practices.user.md
  @product/guidance/agent-operating.md
  @product/guidance/permissions.md
  ```

  The thing that *knows it is a bus* does the layering. Every include points at a
  path inside the bus; none escapes the repo. If a deployment has no user overlay,
  the bus simply omits that one line (or ships an empty file) — the product base
  still applies in full.

Why this direction (reversing v3): in v3 the product's own `best-practices.md`
ended with `@../../memory/best-practices.user.md`, reaching two levels up out of
the product into its mount context. That made the publishable artifact depend on
being mounted at `product/` inside a bus, and a standalone checkout would resolve
that include to *the parent directory of wherever it was cloned* — outside the
repo, possibly onto an unrelated file. Moving composition into the bus keeps the
product genuinely provider-agnostic and keeps the general/user boundary identical
to the lore boundary: the reusable part is product; the deployment-specific part
is a text record in the library that rides the same one-pull propagation.

## 7. Migration plan

The bus is append-only, so this can be staged in a quiet window without stopping
coordination.

1. **Extract product with history — but not the contaminated file.** From a mirror
   clone, `git filter-repo --path spec --path skills --path hooks --path templates
   --path guidance --path README.md --path INSTALL.md --path .gitignore --path
   .gitattributes`, **then drop `guidance/best-practices.md` from the result** —
   e.g. exclude it with `--path-glob '!guidance/best-practices.md'` (or a second
   `filter-repo --invert-paths --path guidance/best-practices.md`) so **no
   revision of the contaminated file enters product history at all**. Author a
   fresh `guidance/best-practices.base.md` (universal rules only, no history) in
   the new **private** `agent-mesh` product repo. Add `install/` +
   `bus-skeleton/` (dirs carry `.gitkeep`). Tag `v0.1.0`.
   *Rationale:* filtering the file in would drag every past revision — with all
   the q8020/`~/proj/src`/sweep content — into product history, leaving a history
   rewrite as the only go-public remedy. Never importing it removes that risk for
   the one file known to be dirty.
2. **Turn the current repo into the bus, and rename it.** The current repo (remote
   `github.com/agallojr/agent-mesh`) becomes the bus: **rename it to
   `agent-mesh-bus`** (GitHub repo rename + `git remote set-url`), freeing the
   `agent-mesh` name for the new product repo. Then `git rm -r` the product paths;
   `git submodule add <product-url> product` pinned to `v0.1.0`. Repoint: skill
   symlink source → `product/skills/…`; the `mesh-on` skill's `${REPO_PATH}/spec`
   and `${REPO_PATH}/guidance` references → `…/product/…`. Update the bus
   `.gitignore` to block blobs (§5, first-line filter) and land the gate's blob
   rejection (§5, enforcement).
3. **Keep the library in place.** `memory/lore/` and `memory/experiments/` (logs)
   stay in the bus — no move, no separate data repo.
4. **Land the user best-practices and wire bus composition.** Add the operator's
   env-specific rules to the bus library as `memory/best-practices.user.md`. Set
   the bus `guidance/CLAUDE.md` to `@`-include both `product/guidance/
   best-practices.base.md` and `memory/best-practices.user.md` (plus the product's
   `agent-operating.md` and `permissions.md`) — the bus owns composition (§6). The
   product base contains **no** reaching include.
5. **Teach the poller to pull *and* realize the pin.** `mesh-on` step 3 and the
   poller pull loop run, with the literal bus path:
   `git -C /abs/bus pull --rebase` **then**
   `git -C /abs/bus submodule update --init --recursive`. The explicit
   `submodule update` — not reliance on a `--recurse-submodules` flag — is what
   deterministically checks out the pinned product commit across git versions and
   configs. Neither op is gated (checkout/update are not add/commit/push), so the
   git gate is unaffected.
6. **Verify one node end-to-end.** Fresh clone of the bus followed by
   `submodule update --init --recursive`, `/mesh-on`, confirm: guidance/protocol
   resolve byte-identically at the `product/` prefix, the composed best-practices
   chain (base + user overlay) loads, latest lore + logs present from the pull, a
   task round-trips, `agents/<id>.yaml` still self-registers, env files still
   gitignored, a blob-class `git add` is rejected by the gate. Then re-point the
   other nodes.
7. **Gate for going public (later).** Before flipping the product repo public:
   secret-scan its full (filtered) history and confirm no credentials or private
   paths remain. Because the contaminated `best-practices.md` was never imported
   (step 1), the highest-risk file is not in product history at all — the scan is
   a confirmation, not a rescue. Only then flip.

## 8. Product delivery — options considered

| Option | One-pull identical? | Update path | Verdict |
|---|---|---|---|
| **Product submodule in the bus** (chosen) | Yes *if* the poller realizes the pin (§7 step 5) | 1 (`pull` + `submodule update`; bump pin to ship) | Matches "bus with product linked in"; clean boundary; works private-now/public-later unchanged. Costs one explicit submodule-update step. |
| Product as release artifact installed into `~/.claude` | Yes if pinned | 2 (pull bus + re-install on product bump) | Cleaner if consumed outside the mesh; more operator steps |
| Product vendored (copied) into the bus | Exactly, *for free* (plain pull, no extra step) | 1 | Only option that preserves one-pull literally, but reintroduces the commingling we're removing |

The submodule choice trades vendoring's *automatic* one-pull for a *realized*
one-pull (poller does `submodule update`). We accept that one step to get a clean,
independently-publishable product boundary — see §1's caveat and §9's footgun
mitigation.

## 9. Risks & mitigations

- **Submodule footguns** (detached HEAD, forgotten checkout, stale working tree):
  bake `git -C /abs/bus submodule update --init --recursive` into the poller
  (§7 step 5) — the *explicit update*, not a client-side `--recurse` flag, is the
  mitigation — and add a `mesh-on` preflight that asserts the `product/` submodule
  is present and at the pinned commit.
- **Gitlink ownership / pin-bump races.** The bus's `.gitattributes` sets
  `* -merge`, so any concurrent edit to a tracked path is a hard conflict by
  design. The `product/` gitlink and `.gitmodules` are now tracked entries, so
  add them to `agent-operating.md`'s owned-paths matrix as **hub/operator-owned**:
  workers never touch them; only the hub/operator bumps the pin. That keeps a
  pin-bump from racing a worker's write.
- **Going public later** (deferred, not now): the contaminated `best-practices.md`
  is never imported into product history (§7 step 1), so the step-7 secret-scan is
  a confirmation over already-clean history rather than a remedy for a known leak.
  Nothing to do while the product stays private.
- **Version drift**: eliminated — the bus pins the product commit, so every node
  that has realized the pin is on the same product. (The pin is the source of
  truth; there is no separate `VERSION` file to fall out of sync — §4.)
- **Single-writer invariant**: unchanged — only the bus is node-writable; the
  product submodule is read-only, blobs live outside the bus entirely, and the
  gitlink/`.gitmodules` are hub/operator-owned.

## 10. Decisions

*Settled:*
- Product code → its own repo, **private for now, public once tested**.
- **Naming: product = `agent-mesh`; bus = `agent-mesh-bus`.** The current repo is
  renamed to `agent-mesh-bus`, freeing `agent-mesh` for the product (the eventual
  public face). Resolves the former §7/§10 collision.
- Library (lore + experiment logs) stays in the bus and propagates by plain pull;
  no separate data repo for logs.
- Best-practices splits: **product ships a self-contained
  `best-practices.base.md`** (universal rules, no reaching include); **the
  user-specific overlay lives in the bus library** (`memory/best-practices.user.md`);
  **the bus's `guidance/CLAUDE.md` composes the two.** The product never reaches
  outside itself, so it stays publishable standalone. The contaminated
  `best-practices.md` is **not** imported into product history — a fresh base is
  authored instead.
- Blob storage is out of scope — user/workflow/experiment-specific. The mesh keeps
  blobs out of the bus and references them by pointer. **Enforcement is the git
  gate** (extended to reject blob-class staging); `.gitignore` is a first-line
  convenience filter, not the boundary.
- Product reaches nodes as a **pinned submodule** of the bus, and the poller
  **realizes the pin** with an explicit `submodule update --init --recursive`
  after each pull.
- Includes use **Claude Code's native recursive `@`-import**, the one mechanism
  already in use — no second agent-driven composition path.
- No `VERSION` file — the submodule pin is the source of truth; derive a
  human-readable tag with `git -C product describe --tags`.

*Still open:*
- Exact **size threshold** for the gate's blob rejection (§5) — pick a default
  (e.g. 5 MB) and let the allowlist/config tune it.
