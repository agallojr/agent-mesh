# Agent Mesh — Separating the Product from the Data

**Design document · draft v5 · 2026-07-20**

> **Status: implemented.** The split described here has been executed. `agent-mesh`
> (product) is **public**; `agent-mesh-bus` (bus) is **private** and references the
> product as a submodule. §7 is retained as the historical migration record.
>
> **Changes since v4 (reflecting what actually shipped).** The product is no
> longer "private for now" — it is **public**, the bus stays private (§2). The
> delivery model changed from a **frozen pin** to **tracking the tip of product
> `main`**: the submodule sets `submodule.product.branch = main` and every sync
> uses `--remote`, so a refresh lands `product/` on the latest `main`, not a
> recorded commit (§1, §4, §8). The poller and a new `pullmesh` alias both use
> `submodule update --init --remote --recursive` (§4, §7 step 5). A plain
> `git pull` re-checks-out the recorded gitlink (which lags `main`); `pullmesh`
> is the one-command manual refresh (§4). The recorded gitlink still exists (it is
> intrinsic to submodules) but is no longer the source of truth — the `main` tip
> is — so the §9 "pin-bump race" is reframed as harmless gitlink churn.
>
> **Changes since v3 (carried forward).** Best-practices composition lives in the
> **bus**, not the product (§6). The contaminated `best-practices.md` is **not**
> filtered into product history; a fresh base is authored (§7). Naming settled:
> product = `agent-mesh`, bus = `agent-mesh-bus` (§4, §10). Blob enforcement is the
> **git-gate hook**, not `.gitignore` alone (§5). `VERSION` dropped (§4).
> `@`-includes use Claude Code's native recursive import (§2, §6).

## 1. Problem

`agent-mesh` is a single Git repo doing three different jobs at once:

1. **Product code** — the mesh protocol, the `mesh-on`/`mesh-off` skills, the
   git-gate hook, env templates, the operating/permission guidance, and (new) an
   installer. Reusable, versionable software.
2. **The coordination bus** — `agents/ tasks/ status/ outbox/ workflows/
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
design, §8) makes it *one-pull-if-the-tip-is-realized*: the pull must be followed
by a `--remote` submodule update that checks out the tip of product `main`. We
keep the property true by baking that step into the poller and into a `pullmesh`
alias for manual use (§4, §7 step 5) rather than trusting a client flag — a plain
`git pull` (even a recursing one) re-checks-out the *recorded* gitlink, which lags
the `main` tip. This is the one place the submodule choice is weaker than
vendoring, and we accept it in exchange for a clean product/bus boundary.

## 2. Terminology (so we stop colliding on words)

| Term | Means | Where it lives |
|---|---|---|
| **product** / **code** | the mesh software: protocol, skills, hooks, templates, guidance, installer | its own repo (`agent-mesh`), **public** |
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
| `agents/`, `tasks/`, `status/`, `outbox/`, `workflows/`, `_archive/` | Bus runtime | Stay in the bus |
| `memory/lore/` | Library | Stay in the bus |
| `memory/experiments/` (the logs) | Library | Stay in the bus |
| (future) large binary results | Blob | Not in the bus; pointer only |

## 4. Target architecture — two repos we build, one boundary we enforce

```
agent-mesh            PRODUCT repo — the software. PUBLIC.
  spec/ skills/ hooks/ templates/ guidance/(sanitized) README INSTALL
  guidance/best-practices.base.md   universal rules only, self-contained (no reaching @-include)
  install/            the installer: scaffolds a fresh bus and links the product in
  bus-skeleton/       dir skeleton for initializing a bus (dirs carry .gitkeep placeholders)

agent-mesh-bus        BUS repo — PRIVATE; the repo every node clones, pulls, pushes.
                      (This is the CURRENT repo, renamed from agent-mesh — see §7 step 2.)
  product/   ->  git submodule TRACKING product main (submodule.product.branch=main)
  .gitmodules         submodule url + branch=main; synced with --remote (§8)
  agents/ tasks/ status/ outbox/ workflows/ _archive/
  memory/             THE LIBRARY (text only):
    lore/                shared, curated by the `librarian` role
    experiments/         experiment logs
    best-practices.user.md   this operator's env-specific rules (composed by the bus, §6)
  guidance/CLAUDE.md  bus entry point: @-includes product/guidance/best-practices.base.md
                      AND memory/best-practices.user.md (the bus owns composition)
  .gitignore (first-line blob filter; real enforcement is the git gate, §5)
```

The bus needs no `VERSION` file, and the recorded submodule commit (the gitlink)
is deliberately **not** the source of truth: the tip of product `main` is. The
submodule is configured with `submodule.product.branch = main`, and every sync
uses `--remote`, so nodes converge on latest `main` regardless of what commit any
particular bus commit happens to record. A human-readable tag, when wanted, is
derived on demand with `git -C product describe --tags`.

**Product delivery = the product repo linked into the bus as a submodule that
tracks `main`.** This is the "installation creates a bus with the product linked
in" model. A node clones the bus and runs
`git submodule update --init --remote --recursive`, which lands `product/` on the
tip of product `main` — so a refresh always runs the latest product code. Product
paths sit under a fixed prefix (`${REPO_PATH}/product/spec/…`), a mechanical
repoint of the skill and guidance references. Shipping a product update mesh-wide
= push to product `main`; nodes pick it up on their next sync, no bus commit
required. Because the product is **public** and the bus **private**, the bus
simply references a public submodule with no extra configuration.

**Refreshing the product — poller vs manual.** The poller runs
`git -C /abs/bus submodule update --init --remote --recursive` every cycle, so
unattended nodes stay on the `main` tip automatically. For a **manual** refresh,
a plain `git pull` is *not* enough: even a recursing pull re-checks-out the
recorded gitlink, which lags the `main` tip. The product therefore ships a git
alias, `pullmesh` = `git pull` followed by the `--remote` submodule update, so one
command (`git -C /abs/bus pullmesh`) advances both the bus and the product tip.
INSTALL registers this alias per clone.

**The library stays in the bus.** `memory/` (an open set of durable-knowledge
categories — lore, experiments, and any others) is written at runtime solely by the
holder of the `librarian` role and is meant to be read by every node — so a plain
`git pull` of the bus delivers the latest knowledge to everyone. It is deliberately
*not* in the product submodule (which tracks the product repo, not deployment state)
and *not* a separate repo (which would break one-pull propagation).

**An outer library repo may wrap the bus (optional deployment layout).** A human
who keeps hand-authored research notes in their own git repo can mount the bus as a
submodule of that notes repo (`--remote`, tracking `main`, the same trick used for
`product/`):

```
research-notes/            OUTER repo — the human's hand-authored notes
  └── bus/  = agent-mesh-bus   (submodule tracking main)
        └── product/ = agent-mesh (submodule)
```

Then a recursive pull of `research-notes` gives the human *everything* — their notes
plus the bus's `memory/`, coordination trail, and product — in one place, while a
node still clones only the bus and gets exactly what it needs. Submodules nest one
direction, so this is a clean single-writer split: the human writes the outer repo,
the `librarian` writes `bus/memory/`, and each node writes only its own
`outbox/`/`status/`. Nothing in the mesh writes or even clones the outer repo.

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
5. **Teach the poller to pull *and* realize the tip.** `mesh-on` step 3 and the
   poller pull loop run, with the literal bus path:
   `git -C /abs/bus pull --rebase` **then**
   `git -C /abs/bus submodule update --init --remote --recursive`. The explicit
   `--remote` update — not reliance on a `--recurse-submodules` flag — is what
   deterministically checks out the tip of product `main` across git versions and
   configs. For manual use, register the `pullmesh` alias (`git pull` + the same
   `--remote` update) so a human refresh gets the tip in one command. Neither op
   is gated (checkout/update are not add/commit/push), so the git gate is
   unaffected. (Originally specified as a frozen-pin `submodule update`; changed
   to `--remote` tip-tracking — see the v5 status note.)
6. **Verify one node end-to-end.** Fresh clone of the bus followed by
   `submodule update --init --remote --recursive`, `/mesh-on`, confirm:
   guidance/protocol resolve byte-identically at the `product/` prefix, the
   composed best-practices chain (base + user overlay) loads, latest lore + logs
   present from the pull, a task round-trips, `agents/<id>.yaml` still
   self-registers, env files still gitignored, a blob-class `git add` is rejected
   by the gate. Then re-point the other nodes.
7. **Go public.** With the contaminated `best-practices.md` never imported (step
   1), the product history carried no known secret. After a confirming secret-scan
   of the filtered history, the product repo `agent-mesh` was flipped **public**;
   the bus `agent-mesh-bus` stays private and references the now-public submodule
   with no change.

## 8. Product delivery — options considered

| Option | One-pull latest? | Update path | Verdict |
|---|---|---|---|
| **Product submodule tracking `main`** (chosen) | Yes *if* the sync uses `--remote` (§7 step 5) | 1 (`pull` + `--remote submodule update`; push product `main` to ship) | Matches "bus with product linked in"; clean boundary; public product / private bus unchanged. Costs one explicit `--remote` submodule-update step. |
| Product submodule frozen to a pinned commit | Yes if the pin is realized | 2 (pull bus + bump pin commit to ship) | Reproducible, but shipping needs a bus commit per update and a plain pull lags — rejected for the mesh's "pull gets latest product" goal |
| Product as release artifact installed into `~/.claude` | Yes if pinned | 2 (pull bus + re-install on product bump) | Cleaner if consumed outside the mesh; more operator steps |
| Product vendored (copied) into the bus | Exactly, *for free* (plain pull, no extra step) | 1 | Only option that preserves one-pull literally, but reintroduces the commingling we're removing |

The submodule-tracking-`main` choice trades vendoring's *automatic* one-pull for a
*realized* one — the sync must use `--remote`. We accept that one step (baked into
the poller and the `pullmesh` alias) to get a clean, independently-publishable
product boundary where pushing to product `main` ships mesh-wide with no bus
commit. See §1's caveat and §9's footgun mitigation.

## 9. Risks & mitigations

- **Submodule footguns** (forgotten `--remote`, stale working tree, a manual
  `git pull` that lags): bake `git -C /abs/bus submodule update --init --remote
  --recursive` into the poller (§7 step 5) — the *explicit `--remote` update*, not
  a client-side `--recurse` flag, is the mitigation — ship the `pullmesh` alias
  for manual refreshes, and have `mesh-on` assert the `product/` submodule is
  present and populated.
- **Gitlink churn (not a race).** Because the working tree tracks the `main` tip
  (not the recorded gitlink), the recorded commit is no longer authoritative — a
  node that stages `product` merely records whatever tip it happened to be on, and
  the next node's sync ignores it and re-resolves `main` anyway. So a moved gitlink
  is cosmetic churn, not a correctness problem. To keep it quiet, the `product/`
  gitlink and `.gitmodules` remain **operator-owned** in
  `agent-operating.md`'s matrix (nodes do not stage them), and the poller's
  `add` need not touch `product`. The bus's `* -merge` still makes any concurrent
  edit a hard conflict by design.
- **Going public**: done (§7 step 7). The contaminated `best-practices.md` was
  never imported into product history (§7 step 1), so the confirming secret-scan
  found nothing to redact and the product was flipped public. The bus stays
  private.
- **Version drift**: nodes converge on the tip of product `main` on every
  `--remote` sync, so they run the same product independent of the recorded
  gitlink. There is no `VERSION` file to fall out of sync (§4). The tradeoff vs a
  frozen pin: no "every node on bus commit X runs product commit Y"
  reproducibility guarantee — deliberately accepted for the "pull gets latest
  product" behavior.
- **Single-writer invariant**: unchanged — only the bus is node-writable; the
  product submodule is read-only to nodes, blobs live outside the bus entirely,
  and the gitlink/`.gitmodules` are operator-owned.

## 10. Decisions

*Settled:*
- Product code → its own repo, now **public**. The bus stays **private**.
- **Naming: product = `agent-mesh`; bus = `agent-mesh-bus`.** The original repo was
  renamed to `agent-mesh-bus`, freeing `agent-mesh` for the (now public) product.
  Resolves the former §7/§10 collision.
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
- Product reaches nodes as a submodule of the bus that **tracks product `main`**
  (`submodule.product.branch = main`); the poller and the `pullmesh` alias
  **realize the tip** with `submodule update --init --remote --recursive` after
  each pull. A plain `git pull` lags (re-checks-out the recorded gitlink), so
  manual refreshes use `pullmesh`. Pushing to product `main` ships mesh-wide with
  no bus commit; the recorded gitlink is not the source of truth.
- Includes use **Claude Code's native recursive `@`-import**, the one mechanism
  already in use — no second agent-driven composition path.
- No `VERSION` file and no authoritative pin — the tip of product `main` is the
  source of truth; derive a human-readable tag with `git -C product describe
  --tags` when wanted.

*Still open:*
- Exact **size threshold** for the gate's blob rejection (§5) — currently 5 MB;
  may expose it as allowlist/config-tunable.
- Whether to have the poller explicitly exclude `product` from its `git add` to
  suppress gitlink churn entirely (§9) — cosmetic, not yet decided.
