---
name: mesh-scratch
description: Start, save or end a spike in the mesh's scratch space (spaces/tmp). Use when you begin throwaway work such as an experiment, a calculation or a demo that is not part of a repo being worked, when you want that work shared with the other nodes of the mesh, or when it is finished and must be filed, spawned into a project or abandoned.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# mesh-scratch - spikes in the scratch space

The scratch space (`<REPO_PATH>/spaces/tmp`, kind `scratch`, librarian `none`)
holds one top-level folder per spike. Any agent of the mesh writes it, with no
librarian and no mesh task. Scratch is never cited from a portable space.

`spike.sh` (next to this file) writes only the outcome file and runs no git
write. It prints each git command as a `RUN ` line. Run those lines in order,
one Bash call per line, exactly as printed, so the git gate sees every literal
path. Stop at the first line that fails.

## Start

Make `<REPO_PATH>/spaces/tmp/<spike>/` and work in it. A spike name matches
`[a-z0-9][a-z0-9._-]*`. Pull first with the `pull --rebase` line of `save`
if other nodes may have written.

## Save

```
sh <skill dir>/spike.sh save <spike> [--root <scratch root>]
```

Prints four `RUN` lines: add the folder, commit it, pull with rebase, push.
The commit holds only that spike's files.

## End

```
sh <skill dir>/spike.sh end <spike> (--filed <space id>/<record id> |
    --spawned proj:<name> | --abandoned) [--why <text>] [--root <scratch root>]
```

File the content first (through `space-librarian` for core or lore), then end
the spike. `end` writes `<spike>.outcome.md` at the scratch root and prints
five `RUN` lines: remove the folder, add the outcome file, commit both, pull
with rebase, push. The one commit removes every file of the spike and adds the
outcome file.

`end` prints `REFUSED <spike>: <reason>`, writes nothing and exits 1 for a bad
spike name, a missing folder, untracked files in the folder (save them first
or delete them), or a `--filed` record found in no file of that space.
