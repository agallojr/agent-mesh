# Installing the mesh on a node

This turns a machine into a mesh node: a Claude agent that joins the
coordination bus, takes tasks addressed to it, and syncs results by git. It
applies equally to the hub laptop and a remote worker doing a fresh install.

The bus is its own git repo (`agent-mesh-bus`). It carries the runtime
coordination state (`agents/`, `tasks/`, `status/`, `outbox/`, `mailbox/`,
`workflows/`) and the memory library (`memory/lore/`, `memory/experiments/`,
`memory/best-practices.user.md`). The product software lives in a git submodule
at `product/`. The submodule tracks the tip of the product's `main` branch
(`submodule.product.branch = main` in `.gitmodules`): a sync checks out the
latest product `main`, not a frozen pin. Every path below that starts with
`${REPO}/product/...` resolves inside that submodule.

## 0. Prerequisites
- git and Python 3 (`/usr/bin/python3` is used by the hook).
- Claude Code installed.
- Network access to the bus repo's git remote.

## 1. Clone the bus and realize the product submodule
Clone `agent-mesh-bus`, not the old `agent-mesh`. After cloning you MUST init
the submodule so the product is checked out under `product/`. Use `--remote` so
`product/` lands on the tip of product `main`, not on the commit the bus
happens to record:

    git clone <bus-url> ~/agent-mesh-bus
    REPO="$HOME/agent-mesh-bus"
    git -C "$REPO" submodule update --init --remote --recursive

Do not rely on `git clone --recurse-submodules` alone. Always run the explicit
`submodule update --init --remote --recursive` step: it is what the poller uses
to sync the product to latest, and it is robust across git versions. Confirm
the submodule is populated:

    ls "$REPO/product/spec/PROTOCOL.md"

If `product/` is empty, the submodule was not realized. See Troubleshooting.

Then register the `pullmesh` alias on this clone, so a later manual refresh gets
the latest product in one command (a plain `git pull` would re-checkout the
recorded commit instead of the `main` tip — see Notes):

    git -C "$REPO" config alias.pullmesh \
      '!f() { git pull "$@" && git submodule update --init --remote --recursive; }; f'

## 2. Install the git gate (hook + settings + allowlist)
2a. Copy the hook and make it executable.

    cp "$REPO/product/hooks/git-gate.py" ~/.claude/hooks/
    chmod +x ~/.claude/hooks/git-gate.py

2b. Seed the allowlist from the template and append the bus clone path. The
path you add here must equal `REPO_PATH` in the identity file (step 4).

    cp "$REPO/product/hooks/mesh-git-allowlist.txt.template" \
        ~/.claude/mesh-git-allowlist.txt
    echo "$REPO" >> ~/.claude/mesh-git-allowlist.txt

2c. Register the PreToolUse Bash hook pointing at
`~/.claude/hooks/git-gate.py` in `~/.claude/settings.json`, remove any blanket
git deny, and keep sudo denied. The snippet uses a `REPLACE_WITH_HOME` token:

    sed "s#REPLACE_WITH_HOME#$HOME#g" \
        "$REPO/product/hooks/settings.snippet.json" > ~/.claude/settings.json

2d. Verify by piping a fake deny case and a fake allow case through the hook
and checking the decisions.

## 3. Install the skills (symlinks)
Symlink the skills from the product submodule so they track the pinned commit.

    ln -sfn "$REPO/product/skills/mesh-on" ~/.claude/skills/mesh-on
    ln -sfn "$REPO/product/skills/mesh-off" ~/.claude/skills/mesh-off

Verify that `SKILL.md` and `poller-prompt.md` resolve through each symlink.

## 4. Plant identity and credentials
Copy the templates from the product submodule, then edit them.

    cp "$REPO/product/templates/agent-identity.env.template" \
        ~/.agent-identity.env
    chmod 644 ~/.agent-identity.env
    cp "$REPO/product/templates/agent-credentials.env.template" \
        ~/.agent-credentials.env
    chmod 600 ~/.agent-credentials.env

Edit `~/.agent-identity.env`: set `AGENT_ID` (`openssl rand -hex 3`),
`AGENT_NAME`, `AGENT_CONTEXT`, `AGENT_ROLE`, `POLL_INTERVAL_SEC`, and
`REPO_PATH`. `REPO_PATH` MUST be the absolute path of the bus clone (the value
of `$REPO`) and MUST appear verbatim in `~/.claude/mesh-git-allowlist.txt`.

## 5. Join the mesh
Start Claude, then run `/mesh-on` to start the node; `/mesh-off` stops it. The
poller is session-scoped, so run unattended nodes under tmux or screen.

## Notes
- Refreshing the product: the automated poller already syncs `product/` to the
  tip of `main` every cycle (`git submodule update --init --remote --recursive`).
  For a manual refresh, run `git -C <REPO> pullmesh` — a plain `git pull` (even
  with `submodule.recurse` set) re-checks-out the commit the bus records under
  `product/`, which lags the `main` tip. `pullmesh` = `git pull` followed by the
  `--remote` submodule update, so one command lands the bus and the product tip
  together.
- Git literal-absolute-path rule: agents must run `git -C /abs/bus <subcmd>`
  with a literal path, never `git -C "$VAR" ...` or `cd ... && git ...`.
  Read-only git (pull, fetch, status, `submodule update`) is not gated.
- The gate rejects staging large or binary blobs into the bus (`*.nc`, `*.h5`,
  `*.hdf5`, `*.ckpt`, `*.npy`, `*.npz`, `*.png`, `*.jpg`, `*.mp4`, `*.tar`,
  `*.zip`, and any file over roughly 5MB). Large results must be referenced by
  pointer in a record's `artifacts` field, not committed to the bus.

## Troubleshooting
- Submodule not checked out / `product/` empty: the clone did not realize the
  submodule. Fix with `git -C <REPO> submodule update --init --remote --recursive`,
  then re-check `ls "$REPO/product/spec/PROTOCOL.md"`.
- Product looks stale after `git pull`: a plain pull re-checks-out the recorded
  `product/` commit, not the `main` tip. Run `git -C <REPO> pullmesh` (or
  `git -C <REPO> submodule update --init --remote --recursive`) to advance to
  the latest product `main`.
- Blob `git add` denied by the gate: you tried to stage a large or binary file
  (see Notes). Do not commit it. Reference the artifact by pointer in the
  record's `artifacts` field and stage only the small text record.
- `REPO_PATH` not allowlisted: push denied. Ensure `REPO_PATH` in
  `~/.agent-identity.env` appears verbatim in `~/.claude/mesh-git-allowlist.txt`.
- Push denied (literal path rule): rewrite the command as
  `git -C /abs/bus <subcmd>` with a literal path, not a variable or `cd`.
- Commit denied: shell operators or command substitution in `-m`. Use a plain,
  quoted commit message with no `$(...)`, backticks, or `&&`/`;`/`|`.
- `$HOME` mismatch vs config dir: the hook and settings resolved a different
  home than expected. Re-run the step 2c `sed` with the correct `$HOME`.
- Skill not appearing: check the symlinks in `~/.claude/skills/` resolve into
  `$REPO/product/skills/` and that `SKILL.md` exists at the target.
- Nothing happens (no tasks): the node is idle because no tasks are addressed
  to its `AGENT_ID`. Confirm identity, then wait for or assign a task.
