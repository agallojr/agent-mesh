---
name: mesh-load
description: Load or drop a project memory space for this session. "load <project>" clones the space on first need, pulls its tip, prints its catalog and adds it to the session's loaded set; "drop <project>" takes it out of the set. For a space the bus does not mount, it prints NOT MOUNTED and the mount commands, then stops. Invoke when the user says "load <project>" or "drop <project>", or asks to load, open or drop a project space.
allowed-tools: Read, Bash, Grep, Glob
---

# mesh-load: load and drop a project space

A memory space (`product/spec/memory-spaces.md`) is a git repo of records. The
bus mounts it as a submodule under `spaces/` and lists it in `spaces.yaml`
(PROTOCOL §3). Mounted is not loaded: a node clones a space only when
something first needs it, and a session sees a space's records only once it
loads it (memory-spaces §4.3, §5). This skill is the session's verb for that:

- **"load <project>"** clones the space if this node has not, pulls its tip,
  prints its catalog and adds it to the session's loaded set.
- **"drop <project>"** takes it out of the loaded set again.

`<project>` is `proj:<name>` or a bare `<name>`; use it as `proj:<name>`. It
must match `^proj:[a-z0-9][a-z0-9-]*$`; if it does not, say so and stop.

**Read-only on the bus.** This skill never edits `spaces.yaml`, `.gitmodules`
or a gitlink, and never stages, commits or pushes, in the bus or in the space.
Its two `submodule update` commands change only the space's own checkout and
the bus's local `.git`. The gitlink drift they leave is hidden by
`ignore = all` and is never committed (memory-spaces §4.2). Mounting is the
operator's step, by hand. A loaded space is read-only to the session too: its
records are written only by the space's librarian (memory-spaces §6.3).

A mesh task that carries `project: proj:<name>` is loaded the same way by the
claiming node's poller (PROTOCOL §5, `skills/mesh-on/poller-prompt.md`). This
skill is the interactive form.

## 1. Find the bus

The bus root is `REPO_PATH` in `~/.agent-identity.env`; without that, the bus
clone this session works in. Write its literal absolute path into every
`git -C` command below (`git -C /abs/bus ...`), never a variable: that is the
mesh's git rule (`guidance/agent-operating.md`). A session with no bus has
nothing to load: it works in its own checkout of the space directly.

## 2. Is the space mounted?

The space is mounted when both hold: `spaces.yaml` has an entry with
`id: proj:<name>` (one-line entries, as the registry is written), and
`.gitmodules` has a submodule at that entry's `path`. Fill in the bus root and
the project:

```sh
B=/abs/bus; P=proj:<name>
entry=$(grep -E "id:[[:space:]]*$P[[:space:]]*[,}]" "$B/spaces.yaml" \
  2>/dev/null | head -1)
path=$(printf '%s\n' "$entry" |
  sed -n 's/.*path:[[:space:]]*\([^,}[:space:]]*\).*/\1/p')
access=$(printf '%s\n' "$entry" |
  sed -n 's/.*access:[[:space:]]*\([a-z]*\).*/\1/p')
if [ -n "$path" ] &&
   git config -f "$B/.gitmodules" --get-regexp '^submodule\..*\.path$' \
     2>/dev/null | cut -d' ' -f2- | grep -qxF "$path"; then
  echo "MOUNTED $P $path ${access:-?}"
else
  echo "NOT MOUNTED $P"
fi
```

If it is not mounted (no `spaces.yaml`, no entry, or no submodule at the
entry's path), print exactly this line:

```
NOT MOUNTED proj:<name>
```

Then print the mount commands below for the operator, with the bus root and
the name filled in, and **stop**. Loading never changes the bus, so this skill
does not run them. The operator runs them by hand, at a terminal with the bus
cloned (memory-spaces §8; `docs/operator-manual.md` section 8):

```sh
git -C <bus root> submodule add -b main <space repo url> spaces/proj-<name>
git -C <bus root> config -f .gitmodules submodule.spaces/proj-<name>.ignore all
# In <bus root>/spaces.yaml, add this line under "spaces:" (an empty
# "spaces: []" becomes "spaces:" followed by the line):
#   - {id: proj:<name>, path: spaces/proj-<name>, access: rw, librarian: librarian}
git -C <bus root> add -- .gitmodules spaces/proj-<name> spaces.yaml
git -C <bus root> commit -m "mount space proj-<name>"
git -C <bus root> push origin HEAD
```

`access` is `ro` when this mesh only reads the space. `librarian` names the
role that files records into it.

## 3. Clone on first need

If `<bus root>/<path>/.git` does not exist, this node has not cloned the
space yet. Initialize its submodule:

```sh
git -C /abs/bus submodule update --init -- <path>
```

If it fails, say so and stop. The usual cause is that this node has no read
access to the space's repo, which the operator grants (operator manual,
section 8).

## 4. Pull its tip

```sh
git -C /abs/bus submodule update --remote --merge -- <path>
```

This follows the tip of the space's branch, as the scanner does on each
cycle once the space is cloned, and keeps any local commit the space's
librarian has made. If it fails, say so and stop.

## 5. Print the catalog

Print the space's id, path, access and commit, then the header of its
`STATUS.md` (everything above the first `## ` heading), then the id and title
of each record in `notes/` and `decisions/`:

```sh
S=/abs/bus/<path>
c=$(git -C /abs/bus/<path> rev-parse --short HEAD)
echo "proj:<name>  <path>  access <access>  $c"
[ -f "$S/STATUS.md" ] && sed -n '/^## /q;p' "$S/STATUS.md"
for d in notes decisions; do
  for f in "$S/$d"/*.md; do
    [ -f "$f" ] || continue
    id=$(sed -n 's/^id:[[:space:]]*//p' "$f" | head -1)
    title=$(sed -n 's/^title:[[:space:]]*//p' "$f" | head -1 |
      sed 's/^"\(.*\)"$/\1/')
    printf '%s  %s\n' "${id:-$(basename "$f" .md)}" "$title"
  done
done
```

From now on the space is in this session's search scope: "consult the
library" covers its records as well as core and lore, by the same grep over
front-matter. Tell the user the space is loaded, and that it is read-only
here. Anything to file in it goes to the space's librarian.

## 6. Record the loaded set

The loaded set is a per-session flag file, keyed by the session id, as
`mm-on` keeps its flag. It lists one space id per line:

```sh
DIR="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/mesh-load"
mkdir -p "$DIR"
F="$DIR/${CLAUDE_CODE_SESSION_ID}.loaded"
touch "$F"
grep -qxF 'proj:<name>' "$F" || printf '%s\n' 'proj:<name>' >> "$F"
echo "loaded: $(tr '\n' ' ' < "$F")"
```

Loading a space that is already loaded runs every step again: it pulls the
tip and reprints the catalog, and step 6 adds no second line.

## Drop

"drop <project>" takes the space out of the loaded set and leaves everything
else as it is:

```sh
DIR="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/mesh-load"
mkdir -p "$DIR"
F="$DIR/${CLAUDE_CODE_SESSION_ID}.loaded"
touch "$F"
grep -vxF 'proj:<name>' "$F" > "$F.new"; mv "$F.new" "$F"
echo "loaded: $(tr '\n' ' ' < "$F")"
```

Dropping narrows the session's search scope back. What the session has
already read stays read. The clone stays on disk, and the scanner keeps
pulling its tip; nothing is deleted. If the space was not loaded, say so.
