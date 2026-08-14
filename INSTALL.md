# Installing the mesh on a node

This turns a machine into a mesh node: a Claude agent that joins the
coordination bus, claims tasks from the role queues it holds, and syncs results by
git. It applies to any node — a laptop or a remote server — doing a fresh install.
(To create a brand-new mesh instead — no bus exists yet — use the installer:
`install/README.md`.)

**The whole install, in one glance.** Five steps, ~10 minutes:

    1. clone the bus + init the product submodule      (git)
    2. install the git gate                            (hook + allowlist + settings)
    3. symlink the skills into ~/.claude/skills/       (mesh-on, mesh-off, ...)
    4. plant ~/.agent-identity.env + ~/.agent-credentials.env
    5. start Claude, run /mesh-on

When you are done the node sits parked on a zero-token scanner, pulls the bus
on a cycle, and claims work addressed to its roles. Nothing further to babysit.

The bus is its own git repo (`agent-mesh-bus-<mesh>`, named for the mesh). It
carries the runtime coordination state (`agents/`, `tasks/`, `status/`,
`outbox/`, `workflows/`) and the memory library (`memory/` — `lore/`, `notes/`,
`refs/`, `workflows/`, `runs/` — plus the deployment's
`memory/best-practices.user.md` overlay). The product software lives in a git
submodule at `product/`. Every path below that starts with `${REPO}/product/...`
resolves inside that submodule.

**Pin semantics — adopter mode (default).** A node rides the **recorded pin**:
`submodule update` (without `--remote`) checks out exactly the product commit the
bus records under `product/`. Nodes do not chase product `main`; a pin only moves
when the operator (or an upgrade) advances it in a bus commit, so one bad push to
product `main` cannot break a fleet. **Developer mode** — the product
maintainer's own mesh — is opt-in: set `MESH_PRODUCT_TRACK=tip` in
`~/.agent-identity.env` and the poller tracks product `main` tip (`--remote`),
advancing the pin at each chained-pin checkpoint. Absent that variable, a node is
in adopter mode.

## 0. Prerequisites
- git and Python 3 (`/usr/bin/python3` is used by the hook).
- Claude Code installed.
- Network access to the bus repo's git remote.

## 1. Clone the bus and realize the product submodule
Clone your bus (`agent-mesh-bus-<mesh>`), not the old `agent-mesh`. After cloning
you MUST init the submodule so the product is checked out under `product/`. In
adopter mode (the default) you do **not** pass `--remote`: `product/` lands on the
exact commit the bus records, which is what every node runs.

    git clone <bus-url> ~/agent-mesh-bus-mymesh
    REPO="$HOME/agent-mesh-bus-mymesh"
    git -C "$REPO" submodule update --init --recursive

Do not rely on `git clone --recurse-submodules` alone. Always run the explicit
`submodule update --init --recursive` step: it is what the poller uses to realize
the recorded pin, and it is robust across git versions. Confirm the submodule is
populated:

    ls "$REPO/product/spec/PROTOCOL.md"

If `product/` is empty, the submodule was not realized. See Troubleshooting.

Then register the `pullmesh` alias on this clone, so a later manual refresh lands
the bus tip and its recorded product pin in one command:

    git -C "$REPO" config alias.pullmesh \
      '!f() { git pull "$@" && git submodule update --init --recursive; }; f'

`pullmesh` = `git pull` (advance the bus to its tip) followed by
`submodule update --init --recursive` (realize whatever product pin that bus tip
records). It does NOT chase product `main`; the recorded pin is the whole point of
adopter mode. (Developer mode adds `--remote` — see the Pin semantics note at the
top and the Notes section.)

This works whether or not the git gate (step 2) is active. The gate still
splits commands on `&&`/`;` before inspecting them, so the alias value (which
contains both) yields fragments shlex cannot tokenize — but the gate now only
fails closed on an unparseable fragment when that fragment names a gated verb
(`add`/`commit`/`push`). `config` is not gated, so it defers (allows) instead of
denying. If for any reason it is still denied, add the alias to `.git/config`
directly, which is what `git config` would do — append under an `[alias]`
section:

    pullmesh = "!f() { git pull \"$@\" && git submodule update --init --recursive; }; f"

Then verify with the read-only `git -C "$REPO" config --get alias.pullmesh`.

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
Symlink every skill from the product submodule so they track the pinned commit.
Loop over the skills directory rather than naming skills individually, so new
skills are picked up automatically:

    for skill in "$REPO"/product/skills/*/; do
        ln -sfn "${skill%/}" ~/.claude/skills/"$(basename "$skill")"
    done

Verify that `SKILL.md` resolves through each symlink.

## 4. Plant identity and credentials
Copy the templates from the product submodule, then edit them.

    cp "$REPO/product/templates/agent-identity.env.template" \
        ~/.agent-identity.env
    chmod 644 ~/.agent-identity.env
    cp "$REPO/product/templates/agent-credentials.env.template" \
        ~/.agent-credentials.env
    chmod 600 ~/.agent-credentials.env

Edit `~/.agent-identity.env`: set `AGENT_ID` (`openssl rand -hex 3`),
`AGENT_NAME`, `AGENT_CONTEXT`, `AGENT_ROLES` (comma-separated — the roles this node
holds and the `tasks/roles/<role>/` queues it will claim from),
`POLL_INTERVAL_SEC`, and `REPO_PATH`. `REPO_PATH` MUST be the absolute path of the
bus clone (the value of `$REPO`) and MUST appear verbatim in
`~/.claude/mesh-git-allowlist.txt`.

### The two env files, and how credentials are managed

These two files are the entire per-node configuration. Both live in `$HOME`,
both are preplanted by the admin (never generated by an agent), and neither is
EVER committed — they are what makes a node *this* node, while everything in
git stays machine-neutral. Normative detail: `spec/PROTOCOL.md` §4.1–4.2.

**`~/.agent-identity.env` (mode 644) — who this node is.** Non-secret:
`AGENT_ID` (opaque routing key — it appears in bus paths, so treat it as
immutable once set; changing it orphans the node's queues), `AGENT_NAME`
(display only, freely mutable), `AGENT_CONTEXT` (coarse environment class that
scopes lore relevance), `AGENT_ROLES`, `POLL_INTERVAL_SEC`, `REPO_PATH`. Mode
644 because nothing in it is sensitive.

**`~/.agent-credentials.env` (mode 600) — what this node may touch.** One
`NAME=value` line per credential (tokens, project ids). Mode 600 because the
values are secrets. The management model is **names travel, values never do**:

- **Values stay on the node.** `/mesh-on` sources this file into the agent's
  environment for use. A value must never appear in a message, status file,
  result, `log_tail`, commit, or transcript — nothing credential-shaped ever
  reaches the bus.
- **Names are published.** At registration the node lists its credential
  *names* in `agents/<id>.yaml`. That is how the mesh knows which node can do
  what without any secret leaving any machine.
- **Tasks reference credentials by name.** A task says "needs
  `EXPORT_API_TOKEN`"; the claiming node checks its own env for that name. If
  it is missing, the node sets the task `blocked` and reports the missing
  **name** — never asking for, or receiving, a value over the bus.
- **Provisioning and rotation are admin actions on the node.** To grant a
  capability, add the `NAME=value` line to that node's file; to rotate,
  replace the value in place. Restart the node (`/mesh-off`, `/mesh-on`) to
  re-source and re-register. The bus never carries the change — only the
  refreshed name list.
- **Defense in depth.** Add both filenames to a global gitignore
  (`git config --global core.excludesFile`), keep tokens fine-grained and
  single-repo (the bus PAT needs Contents read/write on the bus repo only),
  and on shared login nodes prefer the site's supported credential mechanism
  where one exists.

## 5. Join the mesh
Start Claude, then run `/mesh-on` to start the node; `/mesh-off` stops it. The
poller is session-scoped, so run unattended nodes under tmux or screen.

## Layout versioning
The mesh version-controls the **bus layout** — the directory shapes and file
contracts the product code assumes — not marketing versions or commits:

- The bus states what it is: `BUS_LAYOUT` at the bus root (an integer).
- The product states what it expects: `product/spec/LAYOUT_VERSION` (an integer).
- The product documents every transition: `product/upgrades/to-<N>.md`, written
  for an agent to execute idempotently, covering bus changes and any node steps.

Every sync compares the two. Equal → proceed (the common case). Bus behind → the
agent applies `product/upgrades/to-<bus+1>.md` … up to `LAYOUT_VERSION` in order,
stamping `BUS_LAYOUT` after each, then proceeds. Bus ahead → this product checkout
is too old for this bus; stop and report, never guess forward. The poller does
this each cycle, so **the operator does nothing** — upgrades are agent-driven and
invisible. Because nodes ride the recorded pin, an upgrade reaches a node only
when the pin advances.

## Notes
- Refreshing the product (adopter mode, default): a sync realizes the product pin
  the bus records — it does NOT chase product `main`. For a manual refresh, run
  `git -C <REPO> pullmesh` = `git pull` (bus tip) + `git submodule update --init
  --recursive` (that tip's recorded pin). A plain `git pull` without the submodule
  update leaves `product/` on the previously realized commit.
- Developer mode (product maintainer's own mesh only): set `MESH_PRODUCT_TRACK=tip`
  in `~/.agent-identity.env`. The poller then syncs `product/` to the tip of
  `submodule.product.branch` (`main`) each cycle with `git submodule update --init
  --remote --recursive`, and the maintainer's chained-pin tooling advances the
  recorded pin at each checkpoint. Absent the variable, a node is in adopter mode.
- Git literal-absolute-path rule: agents must run `git -C /abs/bus <subcmd>`
  with a literal path, never `git -C "$VAR" ...` or `cd ... && git ...`.
  Read-only git (pull, fetch, status, `submodule update`) is not gated.
- The gate rejects staging large or binary blobs into the bus (`*.nc`, `*.h5`,
  `*.hdf5`, `*.ckpt`, `*.npy`, `*.npz`, `*.png`, `*.jpg`, `*.mp4`, `*.tar`,
  `*.zip`, and any file over roughly 5MB). Large results must be referenced by
  pointer in a record's `artifacts` field, not committed to the bus.

## Troubleshooting
- Submodule not checked out / `product/` empty: the clone did not realize the
  submodule. Fix with `git -C <REPO> submodule update --init --recursive`,
  then re-check `ls "$REPO/product/spec/PROTOCOL.md"`.
- Product not on the pin you expect: adopter mode realizes the commit the bus
  records, not the `main` tip. Run `git -C <REPO> pullmesh` (or
  `git -C <REPO> submodule update --init --recursive`) to land the bus tip and its
  recorded pin. To follow `main` tip instead, that is developer mode
  (`MESH_PRODUCT_TRACK=tip`) — not the default; do not enable it on adopter nodes.
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
- Testing with local `file://` remotes: modern git blocks the `file` transport
  for submodules by default (`fatal: transport 'file' not allowed`), so
  `submodule add`/`update` fail against a local product repo. For a sandbox
  test only, set `git config --global protocol.file.allow always` in the
  sandbox HOME. Real installs over `git@`/`https://` are unaffected.
