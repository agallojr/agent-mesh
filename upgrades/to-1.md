# Upgrade bus layout 0 -> 1

An agent executes this note to bring an **unstamped** bus (layout 0: no
`BUS_LAYOUT` file) up to layout 1. It is idempotent — every step checks before
it writes, so re-running it is safe and a no-op once the bus is already at 1.
Run it against the bus root (`<bus>` below is the literal absolute bus path,
e.g. the node's `REPO_PATH`).

What layout 1 adds over an early bus: a bus-owned `guidance/CLAUDE.md` composer,
the full `memory/` category set, the operator overlay stub, a bus `skills/`
overlay, and the `BUS_LAYOUT` stamp itself.

## Bus steps (write into `<bus>`, then commit)

1. **Composer — `<bus>/guidance/CLAUDE.md`.** If it does not exist, create it
   with exactly this content (the same the installer writes):

   ```
   # Mesh agent guidance -- bus entry point (composes product base + user overlay)

   @../product/guidance/best-practices.base.md
   @../memory/best-practices.user.md
   @../product/guidance/agent-operating.md
   @../product/guidance/permissions.md
   ```

   If it already exists, leave it untouched. Remove a now-dead
   `<bus>/guidance/.gitkeep` if the composer replaces it.

2. **Library categories.** Ensure each of these exists with a `.gitkeep`:
   `<bus>/memory/lore/`, `<bus>/memory/notes/`, `<bus>/memory/refs/`,
   `<bus>/memory/workflows/`, `<bus>/memory/runs/`. Create only the missing
   ones; do not disturb any records already present.

3. **Operator overlay stub — `<bus>/memory/best-practices.user.md`.** If it does
   not exist, create it with exactly this placeholder (the same the installer
   writes):

   ```
   <!-- Add this deployment's specific rules here. This user overlay is composed
        after the product base by guidance/CLAUDE.md. -->
   ```

   If it already exists, leave it untouched (it may hold real rules).

4. **Instance skills overlay — `<bus>/skills/`.** Ensure the directory exists
   with a `.gitkeep`, and a short `<bus>/skills/README.md` if absent, explaining
   the overlay: a bus skill directory with the same name as a product skill wins
   at node link time (the installer links product skills first, then bus skills,
   so a same-named bus skill overwrites the product link). Skill descriptions say
   *when* to invoke a skill — never a standing behavioral directive; those belong
   in the guidance overlay.

5. **Stamp — `<bus>/BUS_LAYOUT`.** Write the file containing exactly `1` and a
   newline.

## Node steps (per machine, in `~/.claude`)

These re-wire this node so it tracks the pinned `product/` instead of a stale
copy. Run them on each node as it upgrades.

1. **Symlink the git gate.** `~/.claude/hooks/git-gate.py` must be a **symlink**
   to `<bus>/product/hooks/git-gate.py`, not a copied file, so it upgrades with
   the pin. If the existing hook is a plain file whose contents are **identical**
   to the pinned target, replace it with the symlink:

   ```
   ln -sfn <bus>/product/hooks/git-gate.py ~/.claude/hooks/git-gate.py
   ```

   If the existing hook's contents **differ** from the pinned target, STOP and
   report — do not overwrite a locally modified hook silently.

2. **Re-link skills including the bus overlay.** Re-run the skill-linking loop so
   product skills are linked first, then any bus overlay skills (a same-named bus
   skill overwrites the product link):

   ```
   for d in <bus>/product/skills/*/; do
     ln -sfn "${d%/}" ~/.claude/skills/"$(basename "$d")"
   done
   for d in <bus>/skills/*/; do
     [ -d "$d" ] || continue
     ln -sfn "${d%/}" ~/.claude/skills/"$(basename "$d")"
   done
   ```

## Commit

Commit the bus changes via the gated flow (literal `-C` path, plain message):

```
git -C <bus> add -A
git -C <bus> commit -m "layout upgrade to 1"
git -C <bus> push origin HEAD
```
