# Agent scratch

This repo is the scratch space of one agent mesh (`kind: scratch` in
`space.yaml`). Any agent of the mesh writes here, without a librarian, and the
operator's sync tool commits and pushes it too. Nothing here is a filed
record: scratch holds work in progress until it is filed into a space, starts
a project, or is dropped.

The bus mounts this repo at `spaces/tmp`. During the change-over, the bus's
`agent-tmp` is a compatibility link to that mount.

## Layout

- One top-level folder per spike, named `[a-z0-9][a-z0-9._-]*`.
- `<spike>.outcome.md` at the root for each spike that has ended.
- `space.yaml`, `.gitattributes`, `.gitignore` and this `README.md`.

## Saving and ending a spike

Use the `mesh-scratch` skill. `spike.sh save <spike>` prints the commands
that commit and push the spike's folder; `spike.sh end <spike>` writes the
outcome file and prints the commands that remove the folder and add the
outcome in one commit. The outcome file:

```
---
spike: <spike>
outcome: filed                    # filed | spawned | abandoned
ended: <YYYY-MM-DDTHH:MMZ>
filed_as: <space id>/<record id>  # outcome filed only
project: proj:<name>              # outcome spawned only
---
<optional reason, one paragraph>
```

## Rules

- Scratch belongs to this mesh only. A record in a shareable space, such as a
  project space or a shared lore space, never cites a file here, and the
  librarian refuses one that does: restate what the record needs inside it.
- A spike stays only until its outcome is recorded (`retention: until-ended`).
- Binary files go through Git LFS, as `.gitattributes` says.
