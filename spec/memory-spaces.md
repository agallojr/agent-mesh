# Memory spaces

**Status: design concept revision 2 (2026-10-27), partly implemented (see
Status below)**

This document is the design of memory spaces: how the Agent Mesh library grows
from one tree, `memory/`, into a set of git repos with their own owners,
visibility, writers and reference rules. The SWE Pod is the first tool to use
one, a project space. PROTOCOL and the `mesh-post` skill cite this document
by its section numbers.

- Revision 1: 2026-10-26.
- Revision 2, from operator review on 2026-10-27:
  - Every space has a librarian, and one librarian may manage several spaces
    (this replaces the per-space steward of revision 1).
  - Lore may be shared, not only private.
  - Spaces are git repos mounted in the bus as submodules, core and lore
    included, so a user picks the spaces their mesh carries.
  - A session loads the spaces it wants. Bootstrap loads core and lore; "load
    projX" clones projX on first need and swaps it in. Mounting a space (adding
    its submodule) is a manual operator step, and retiring one unlinks its
    submodule.

## Status

What this version of the product implements. Sections the table does not name
are the model and rules the implemented parts follow.

| Part | Design | Status | In the product |
|---|---|---|---|
| Project spaces mounted by hand as bus submodules under `spaces/`, each with a `spaces.yaml` entry | §4, §8 (mount, retire), §9 step 1 | implemented | PROTOCOL §3; `docs/operator-manual.md`; `bus-skeleton/spaces.yaml` |
| Clone on first need, when a session or a claimed task loads the space; each pull then follows the tip of every project space the node has cloned | §4.2, §4.3 | implemented | `skills/mesh-load/`; `skills/mesh-on/poller-prompt.md`; `skills/mesh-on/mesh-scan-loop.sh` |
| Loading by "load <project>" (and "drop <project>"), with a per-session loaded set and the catalog of the space added | §5 | implemented | `skills/mesh-load/` |
| Loading by a task's `project:` field | §5 | implemented | PROTOCOL §5; `skills/mesh-post/` (`--project`); `skills/mesh-on/poller-prompt.md` |
| One librarian per space, filing with profile, reference and id checks | §6.3 | implemented | `skills/space-librarian/`; `guidance/agent-operating.md` |
| A shared lore space | §9 step 2 | not yet | none |
| Core and personal lore split out of `memory/` into spaces | §9 step 3 | not yet: `memory/` and PROTOCOL §7 keep today's layout | none |
| The `active:` registry default | §4.3, §5 | not yet: nothing reads `active:`, so a project loads only by name or by task | none |
| Auto-load at session start: a session opened in a space's directory loads that space | §5 | not yet | none |
| The session-start catalog: bootstrap prints the catalog for core and lore | §5 | not yet: core and lore load as `memory/` does today | none |

## 1. Summary

Today the Agent Mesh library is one tree, `memory/`, with five categories and
one writer, the librarian. This concept lifts it one level: the library is a set
of **memory spaces**. A space is a git repo of self-describing records with a
declared owner, visibility, writer model and reference policy. The categories
live inside spaces.

The bus mounts the spaces this user wants as git submodules: one core, one or
more lore spaces, and any number of project spaces. It stores only a pointer
to each, never their contents.

| Kind | Id | Holds | Visibility | Writer model |
|---|---|---|---|---|
| **core** | `core` | The user's own durable knowledge: notes, refs, runs, workflows | private | single-writer |
| **personal lore** | `lore` | Verified operational hints about this user's own machines and setup | private | single-writer |
| **shared lore** | `lore:<name>` | Operational hints that hold for anyone in a group, stated without private detail | shared | multi-actor |
| **project** | `proj:<name>` | Everything a project's participants need to continue the work | shared | multi-actor |

A mesh has exactly one core and one personal lore, and any number of shared
lore and project spaces. Any shared space may instead be public. Every space
has exactly one librarian per mesh, the mesh's only writer to it; one librarian
may manage several spaces. A **Project Space** is a concept, a kind of memory
space, not a product; tools such as the SWE Pod define what goes in one.

## 2. Why spaces, not more categories

Categories answer *what kind of record is this*. They cannot answer the
questions that come up once memory is shared beyond one user:

- **Who may read it?** A project's records go to collaborators; core never does.
- **Who may write it?** Core has one writer. A project space or a shared lore
  space has several actors, most of them outside the mesh.
- **What may it link to?** A shared record that cites a private one leaks it,
  or dangles once the space is handed to someone who cannot see it.
- **What travels together?** A project handoff moves a whole space, not a
  category.

Those are properties of a body of records, not of a record kind, so they belong
one level up.

## 3. The space model

### 3.1 Space manifest

Each space declares itself in `space.yaml` at the root of its repo.

```yaml
space: 1                      # manifest schema version
id: proj:fvm-vqls             # core | lore | lore:<name> | proj:<name>
kind: project                 # core | lore | project
title: VQLS backend for the fvm nozzle solver
visibility: shared            # private | shared | public
owners: [<handle>]            # human handles accountable for the space
writer_model: multi-actor     # single-writer | multi-actor
categories: [notes, lore, decisions, evidence, handoffs]
header_profile: shareable     # mesh | shareable (see 3.3)
may_reference: []             # other shared or public space ids records may cite
retention: until-archived
```

The categories a space allows are its own. Core keeps notes, refs, runs and
workflows; lore spaces keep lore, as PROTOCOL §7 defines them. A project space
declares what its tool needs (the SWE Pod adds `decisions`, `evidence`,
`handoffs`, `changes` and `tests`).

### 3.2 Visibility sets reference direction

Visibility is ordered: **private > shared > public**. The one rule:

> A record may cite a record in a space of equal or wider visibility, never
> narrower.

So core and personal lore may cite shared lore and project records. A shared
lore or project record may cite another shared or public space it lists in
`may_reference`, but never core or personal lore. This is PROTOCOL §12's
"nothing references upward" restated as a property of spaces, and it is what
keeps a handed-off space clean: anything it cites is something its new owner can
also see.

When a shared space depends on a private fact, the fact is restated inside it
as its own record. That small duplicate is deliberate.

**Promoting lore.** A personal lore record that turns out to hold for others is
restated in shareable form, as a new record in the shared lore space, with
hostnames, node ids and home paths replaced by environment classes. The
personal record then gets `superseded_by: lore:<name>/<id>`, which the rule
allows because private may cite shared.

### 3.3 Header profiles

All spaces use the PROTOCOL §7 common record header. Spaces differ in which
identity fields they allow:

| Field | `mesh` profile (core, personal lore) | `shareable` profile (shared lore, project) |
|---|---|---|
| `discovered_by`, `submitted_by` | agent id | actor: human handle or `handle/agent-label` |
| `participants`, `nodes` | agent ids, hostnames | actors; environment classes only |
| `contexts` | environment class | environment class (unchanged) |
| `source_path` | absolute path or URL | URL or path relative to the space |
| `discovered_in` | mesh task id | change or task id within the space |

The shareable profile holds no hostname, node id, home-directory path, mesh
role name, or credential name. A librarian refuses to commit a record that
breaks its space's profile (§6.3).

Tool-specific fields use an `x-` prefix, so a generic reader ignores them
safely.

### 3.4 Identifiers

- Inside a space, records cite each other by bare id, as today.
- Across spaces, the id is qualified: `proj:fvm-vqls/note-20261102T1412Z-3c9e`.
  Bare ids in core and personal lore keep meaning core or personal lore, so
  existing records need no change.
- A citation may pin a commit, `proj:fvm-vqls/note-20261102T1412Z-3c9e@3f9c2ab`,
  when the citing record depends on that exact text. Unpinned means "current".
- **Multi-actor spaces need ids that cannot collide.** A per-day counter such
  as `lore-20261101-0001` is safe only with one writer; two meshes writing one
  space would both allocate `-0001`. In a multi-actor space a new id is the
  category, the UTC minute and four random hex digits:
  `lore-20261027T1845Z-7f3a`. Single-writer spaces keep their counters.
- A space id outlives renames of its repo; the registry maps id to path, and
  `.gitmodules` maps path to remote.

## 4. Mounting

### 4.1 Spaces are submodules of the bus

```
bus/
  agents/ tasks/ status/ outbox/ workflows/    coordination, unchanged
  product/                                     submodule, unchanged
  spaces.yaml                                  registry (§4.3)
  spaces/
    core/                 submodule: core space repo, private
    lore/                 submodule: personal lore repo, private
    lore-cfd-group/       submodule: shared lore repo
    proj-fvm-vqls/        submodule: project space repo
```

Each space is its own repo, with its own remote, access list and LFS store. The
bus's history holds only a gitlink (a commit id) and the URL in `.gitmodules`.
That is why nesting is safe here: mounting a shared space in a private bus
carries none of the bus into the space and none of the space into the bus. A
space's collaborators never see the bus.

Registered submodules under `spaces/` are the one sanctioned kind of nested
repo in the bus. Repos cloned for reading still go to a directory outside
every repo.

### 4.2 Follow tips, not pins

Spaces change on every librarian write, so the bus treats their gitlinks the
way it already treats `product/`:

```
[submodule "spaces/proj-fvm-vqls"]
    path = spaces/proj-fvm-vqls
    url = <git url>
    branch = main
    ignore = all
```

- Nodes read the tip of each space's `main`: on each pull they run
  `git submodule update --init --remote --merge` for the spaces they use.
- A librarian write is a commit and push in the space's own repo. It never
  touches the bus.
- A gitlink moves only when someone wants a checkpoint of which space commits
  went together, in a dedicated bus commit. Routine writes never bump it.
  Because of `ignore = all`, `git status` hides gitlink drift; check with
  `git ls-tree HEAD spaces/<path>`.

### 4.3 Registry

`spaces.yaml` in the bus, written by the operator, says how this mesh uses each
mounted space:

```yaml
spaces:
  - {id: core,           path: spaces/core,           access: rw, librarian: librarian}
  - {id: lore,           path: spaces/lore,           access: rw, librarian: librarian}
  - {id: lore:cfd-group, path: spaces/lore-cfd-group, access: rw, librarian: librarian}
  - {id: proj:fvm-vqls,  path: spaces/proj-fvm-vqls,  access: rw, librarian: librarian}
active: [proj:fvm-vqls]       # default active project spaces (§5); not yet read
```

- **ro**: the mesh reads and searches; it never writes. Fits a space published
  by someone else.
- **rw**: the mesh also writes, through the space's librarian only.

If `spaces.yaml` is absent, no spaces are mounted. A new bus starts with
`spaces: []`.

**Clone on first need.** A node initializes a space's submodule the first time
a session or task on that node loads it (§5). The others stay empty
directories, so carrying many mounts costs a node nothing until it uses one.
Because every mount is a submodule of the bus, one pull brings a node every
mount change, and each space's own push goes to that space's repo.

## 5. Loading spaces

Mounted is not the same as loaded. A mounted space is listed in the bus and
searchable on request. A loaded space is swapped into a session: its records
shape what the session sees and where it looks first.

| Space | Loaded |
|---|---|
| core, personal lore | always, by the bootstrap guidance ("load core and lore") |
| shared lore | by default; matched to the session by `contexts`, as lore is today |
| project | only when asked for |

**"Load projX."** The one verb a session needs. In order:

1. If `proj:projX` is not mounted, stop: say so, and give the operator the
   mount commands (§8). Loading never changes the bus.
2. If this node has not cloned it, initialize the submodule (clone on first
   need).
3. Pull its tip and swap it into the session: print its catalog and add it to
   the session's search scope. The loaded set is a per-session flag, like
   `mm-on`'s.

A project space is also loaded, without asking, from the first of these that
applies:

- **A task names it.** A mesh task carrying `project: proj:<name>` loads that
  space for its executor (PROTOCOL §5).
- **The session starts inside it.** A session opened in a space's directory
  loads that space. Not yet implemented (see Status).
- **The registry default.** `active:` in `spaces.yaml` lists projects every
  session loads. Not yet implemented (see Status).

What loading changes:

- **The catalog** lists lore from every loaded lore and project space,
  filtered by `contexts`. For each loaded project space it adds the
  `STATUS.md` header and the id and title of each note and decision. Bootstrap
  prints it for core and lore (not yet implemented, see Status); each later
  load prints it for the space added.
- **Search.** "Consult the library" covers loaded spaces by default. A mounted
  space that is not loaded is searched only when named.
- **Unloading** ("drop projX") narrows the search scope. What the session
  already read stays read.

This keeps the catalog short however many projects are mounted, and keeps one
project's notes out of another project's session unless asked.

## 6. Writing

### 6.1 Writer models

| Model | Spaces | Rule |
|---|---|---|
| single-writer | core, personal lore | The librarian is the sole writer, as PROTOCOL §7 requires today. |
| multi-actor | shared lore, project | Several actors write. Conflicts are avoided by layout and ids (§6.2, §3.4), not by a coordinator. Each mesh is one actor, through its librarian for that space. |

### 6.2 Conflict-free layout for multi-actor spaces

- **One file per event** for anything append-only (decisions, evidence,
  handoffs, notes, lore), with a collision-free id. Two actors never write the
  same file.
- **Mutable files have one owner at a time**, named in the file's own metadata.
  The owner is set by commit; the first push wins; a losing actor re-reads and
  re-applies intent, never merging text (PROTOCOL §1 invariant 7).
- **Generated views** (an index, a status page) are rebuilt from the records,
  so any actor may regenerate them and they never conflict.

The tool using a space decides which of its files are mutable and who owns
them. The SWE Pod's rules are in its own spec.

### 6.3 The librarian

Every space has exactly one librarian per mesh, its only mesh writer, and one
librarian may manage several spaces. Today the mesh's `librarian` manages core
and lore; the registry names the librarian of every other mounted rw space, by
default that same `librarian`. A second librarian, with a role named
`librarian.<label>`, is added only when some spaces should be managed from
another node. For each space it manages, the librarian:

- Files the records other mesh agents deliver to their own outbox: in the
  space's submodule, on `main`, one commit per transition, then a push to the
  space's remote.
- On push rejection, re-reads the space and re-applies.
- Writes the space first and the bus second (the task's status). A drain
  interrupted between the two is repeated safely, because a record whose id is
  already in the space is not filed again.
- Checks every outgoing record against the space's header profile and
  reference policy, and refuses one that names a host, a node id, a home path,
  or cites a narrower space.
- Is the only node that needs push credentials for the space.

## 7. Routing knowledge between spaces

When a mesh agent learns something, the first yes decides where it goes:

1. Would the space's next participant need it to continue the work? → that
   project space.
2. Is it true regardless of project (environment, tooling, machines)?
   - It holds for others in a shared lore space's group and can be said without
     private detail → that shared lore space, with
     `discovered_in: proj:<name>/<id>` when a project surfaced it.
   - Otherwise → personal lore.
3. Is it about the user's program across projects, or their own plans? → core.
4. Is it private thinking or drafting? → the user's notebook, outside the mesh.

Never copy between spaces. Cite by qualified id instead, in the allowed
direction, or promote (§3.2).

## 8. Space lifecycle

| Event | What happens |
|---|---|
| Create | Create the repo with its `space.yaml`. |
| Mount | Manual, by the operator: `git submodule add` under `spaces/`, set `branch` and `ignore` (§4.2), add the `spaces.yaml` entry, commit the bus. Nodes initialize it on first need. |
| Load | Per session, per task, or by the registry default (§5). |
| Hand off | Ownership changes in `space.yaml` (`owners`); this mesh's librarian stops writing; core keeps a pointer note. The space itself carries everything else. |
| Retire (unmount) | Unlink the submodule: `git submodule deinit` and `git rm` the path, and remove the `spaces.yaml` entry. The space's repo is untouched and can be mounted again. Records that cited the space keep their qualified ids and stop resolving on this mesh. |
| Archive | Mark `retention` terminal in `space.yaml`; the repo is read-only by convention. |

A second mesh is made by cloning one (Agent Mesh). Mounts are per mesh, so the
same shared lore or project space can be mounted by several meshes. Each mesh is
one actor, writing through its own librarian for that space. Meshes never read
each other's core or personal lore.

## 9. From today's `memory/` to spaces

The model holds before any of this moves, because a space is logical. In
order, each step useful on its own:

1. **Project spaces as submodules.** New repos only; nothing moves.
   Implemented (see Status).
2. **A shared lore space**, when the first record warrants one. Promote into it
   per §3.2. Not yet.
3. **Split `memory/`** into a core repo (notes, refs, runs, workflows) and a
   personal lore repo, keeping history (`git filter-repo` per path), and push
   their LFS objects to the new remotes. Replace `memory/` with submodules at
   `spaces/core` and `spaces/lore`. Update every path reference: the
   session-start lore hook, the mesh skills, PROTOCOL §3 and §7, and the
   guidance. Record ids do not change. Compatibility symlinks
   (`memory/notes -> ../spaces/core/notes`, `memory/lore -> ../spaces/lore`)
   can bridge one transition period. Not yet.

## 10. Changes to the Agent Mesh

The whole design needs these changes. The Status table says which parts this
version has.

1. **PROTOCOL §3:** `spaces/` submodules and `spaces.yaml` in the layout; the
   writer table gives `spaces.yaml` to the operator and each space's contents to
   its librarian, in the space's own repo. `memory/` moves at §9 step 3.
2. **PROTOCOL §7:** spaces above categories; one librarian per space, one
   librarian for several spaces allowed.
3. **PROTOCOL §12:** restate the plane boundary as the visibility rule (§3.2).
4. **Ids:** qualified cross-space ids with optional commit pin; collision-free
   ids in multi-actor spaces.
5. **Header profiles:** document `mesh` and `shareable`; add the librarian's
   profile check.
6. **Loading:** the bootstrap guidance loads core and lore; the per-session
   loaded set, the `active` default and the task `project` field; the catalog
   and the library search span loaded spaces.
7. **Git gate:** librarian commits inside `spaces/<path>` count as routine mesh
   traffic, as `memory/` writes do today. Gitlink bumps are checkpoints only.
8. **Operator guidance:** registered submodules under `spaces/` are the
   exception to "never clone a git repo into the bus", and space gitlinks fall
   under the routine-traffic pin exception.
9. **Skills:** `mesh-load` (clone on first need, swap in; for an unmounted
   space, print the mount commands and stop). Mounting and retiring stay
   manual operator steps. Plain words ("load projX", "drop projX") reach the
   skill.

## 11. Open questions

- **Public lore.** A shared lore space published as `public` fits the model
  unchanged. Not needed now.
- **Default loaded projects.** Proposed: none in `active:` until the operator
  sets one; sessions load what they need.
- **Trust in shared lore.** Records written by other meshes. Proposed: trust as
  today, by `contexts`, `verified_on` and `verified_by`; a reader that finds a
  record wrong files a superseding one rather than editing it.
- **Index view.** Proposed: generated per space, never authoritative, as
  PROTOCOL §7 already says of indexes.
