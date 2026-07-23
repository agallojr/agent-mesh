# Reinstall a Node After the Bus/Product Split

For operators (or a node's own Claude agent) migrating an EXISTING worker
node that was cloned before the mesh was split into two repos. Use this when
`git pull` on an old clone conflicts, `product/` is missing, or the top-level
`spec/ skills/ hooks/ guidance/ templates/` dirs are still tracked directly.

## What changed

The mesh was one repo mixing product code and coordination state. It is now two:

- The old `agent-mesh` was renamed on GitHub to `agent-mesh-bus` — the
  coordination bus every node pulls/pushes. The old name still redirects, but
  update the remote explicitly.
- A new `agent-mesh` repo holds ONLY product code and is linked into the bus
  as a git submodule at `product/`, pinned to a tagged commit.

Target layout after migration:

```
<REPO>/                     the bus clone; REPO_PATH points here
  product/                  submodule -> agent-mesh @ pinned tag (product code)
  agents/ tasks/ status/ outbox/ workflows/ _archive/
  memory/lore/ memory/experiments/ memory/best-practices.user.md
  guidance/CLAUDE.md         bus entry point (@-includes product + user rules)
  .gitmodules .gitignore .gitattributes
```

Product paths now live under `${REPO}/product/...`:
- gate hook source: `${REPO}/product/hooks/git-gate.py`
- skills: `${REPO}/product/skills/mesh-on`, `${REPO}/product/skills/mesh-off`
- protocol/guidance: `${REPO}/product/spec/PROTOCOL.md`, `${REPO}/product/guidance/...`

## Option A — Fresh re-clone (recommended)

Because bus history was rewritten around the split, a fresh clone is cleanest.

1. Stop the node with `/mesh-off`; confirm no in-flight task is mid-write
   (stale in-flight work may be dropped — accepted).
2. Move the old clone aside: `mv ~/agent-mesh ~/agent-mesh.old`. Keep it until
   the new clone is verified; do not delete blindly.
3. Clone and init the submodule:
   ```
   git clone <agent-mesh-bus-url> ~/agent-mesh
   git -C ~/agent-mesh submodule update --init --recursive
   ```
   Do not skip the submodule step — it checks out the pinned product commit;
   `product/` is empty without it.
4. Re-point the install to the product submodule paths:
   ```
   cp "$REPO/product/hooks/git-gate.py" ~/.claude/hooks/git-gate.py
   chmod +x ~/.claude/hooks/git-gate.py
   ln -sfn "$REPO/product/skills/mesh-on"  ~/.claude/skills/mesh-on
   ln -sfn "$REPO/product/skills/mesh-off" ~/.claude/skills/mesh-off
   ```
   Confirm `~/.agent-identity.env`'s `REPO_PATH` still equals the clone path
   and is still on `~/.claude/mesh-git-allowlist.txt`. If the clone path
   changed, update BOTH.
5. `/mesh-on`; confirm registration re-lands in `agents/<id>.yaml`, guidance
   and protocol resolve under `product/`, and a task round-trips.

## Option B — In-place remote re-point (only if you must keep the clone)

1. `/mesh-off`.
2. Point the remote at the renamed bus:
   `git -C ~/agent-mesh remote set-url origin <agent-mesh-bus-url>`
3. History was rewritten, so a plain pull will conflict; a hard reset is
   usually required:
   ```
   git -C ~/agent-mesh fetch origin
   git -C ~/agent-mesh reset --hard origin/main
   ```
   WARNING: this discards any uncommitted local state. Only acceptable if the
   node has none it cares about.
4. `git -C ~/agent-mesh submodule update --init --recursive`.
5. Re-point gate + skills to `product/...` as in Option A step 4; verify
   identity and allowlist.
6. `/mesh-on` and verify.

## Notes

- The literal-absolute-path git rule is unchanged: `git -C /abs/bus ...`,
  never `git -C "$VAR"` or `cd && git`.
- The gate now also rejects committing large "blob" files to the bus —
  reference them by pointer in `artifacts` instead.
- A node's AGENT_ID does not change across re-install — it is immutable and
  keeps the node's identity and paths stable.

## Verification checklist

- [ ] `product/` is non-empty (submodule checked out at the pinned tag).
- [ ] guidance/protocol resolve under `product/`.
- [ ] registration landed in `agents/<id>.yaml`.
- [ ] a query round-trips through the mesh.
