# agent-mesh installer

`install.sh` scaffolds a fresh agent-mesh **bus** on this node from the
product's `bus-skeleton/`, pins the product code as a git submodule at a chosen
tag, and wires the git gate plus the `mesh-on` / `mesh-off` skills into
`~/.claude`. Run it from a clone of the **product** repo.

## Step 0 — create your bus remote (do this first)

The installer scaffolds the bus *contents* locally and pushes them to a remote
you already own; it does not create the remote for you. Before running it:

1. Create an **empty, private** repository on your Git host — no README, no
   `.gitignore`, no license (the installer fills it). This is your bus; the
   recommended naming convention is `agent-mesh-bus-<user>` (one bus per user
   mesh). Its clone/SSH URL is the `BUS_URL` below.
2. Keep it **private**. The bus holds your runtime coordination ledger,
   credential *names*, and deployment-specific rules (`best-practices.user.md`).
   The product repo is public; your bus should not be. A private bus can still
   reference the public product submodule with no extra configuration.

You do not create a separate product remote — `PRODUCT_URL` points at the
existing (public) product repo you cloned this from.

## What it does

1. Confirms it is running inside a product checkout (`spec/PROTOCOL.md` and
   `bus-skeleton/` must exist), resolving the product root from the script's
   own location.
2. Creates `BUS_PATH` if absent: `git init`, copies the `bus-skeleton/`
   contents (including `.gitkeep`, `.gitignore`, `.gitattributes`), and sets
   the `origin` remote to `BUS_URL`.
3. Adds the product as a submodule at `product/`. If `PRODUCT_TAG` is set it
   checks that tag out inside the submodule; if unset it pins whatever `HEAD`
   the submodule clone landed on. Then stages `.gitmodules` and the `product`
   pointer.
4. Ensures the bus-owned entry point `guidance/CLAUDE.md` (composing the product
   base and the user overlay), the `memory/best-practices.user.md` placeholder,
   and the `BUS_LAYOUT` stamp exist. The layout-1 `bus-skeleton/` normally ships
   all three, so these steps are an idempotent fallback that only writes what a
   pre-existing bus path is missing.
5. Wires the git gate on this node: **symlinks** `git-gate.py` from the pinned
   `product/hooks/` into `~/.claude/hooks/` (so it upgrades with the pin, not a
   stale copy), appends `BUS_PATH` to `~/.claude/mesh-git-allowlist.txt` (created
   from the template if missing, no duplicate lines), and reminds the operator to
   register the PreToolUse hook in `~/.claude/settings.json`. It does not edit
   `settings.json` itself.
6. Symlinks the skills into `~/.claude/skills/`: every product skill first, then
   any bus overlay skill under `<bus>/skills/` — so a same-named bus skill
   overwrites the product link (the instance override wins).
7. Prints next steps: plant the identity/credentials env files, run the bus's
   first commit and push, register the hook, then `/mesh-on`.

## Inputs

Set as environment variables or pass the matching flag (the flag wins):

| Env var       | Flag            | Meaning                                   |
| ------------- | --------------- | ----------------------------------------- |
| `PRODUCT_URL` | `--product-url` | git URL of the agent-mesh product repo.   |
| `PRODUCT_TAG` | `--product-tag` | product tag to pin (optional; unset pins clone `HEAD`). |
| `BUS_URL`     | `--bus-url`     | git URL of your bus remote (`agent-mesh-bus-<user>`). |
| `BUS_PATH`    | `--bus-path`    | absolute path for the bus clone.          |

## Example

```sh
PRODUCT_URL=git@github.com:you/agent-mesh.git \
BUS_URL=git@github.com:you/agent-mesh-bus-you.git \
BUS_PATH="$HOME/agent-mesh-bus-you" \
./install/install.sh --product-tag v0.1.0
```

`--product-tag` is optional. Omit it to pin whatever commit the submodule clone
lands on (e.g. a product repo that has no tags yet). Nodes ride this recorded
pin; the poller does not chase product `main` unless the node opts into developer
mode (`MESH_PRODUCT_TRACK=tip`). See `INSTALL.md` for the pin semantics.

## Network-mutating steps

The installer never pushes to a remote on its own. The bus's first
`git add -A` / `git commit` / `git push -u origin HEAD` are **printed** at the
end for the operator to run and confirm. All other work (init, submodule add,
local file copies, hook and skill wiring) is local and idempotent where
reasonable.
