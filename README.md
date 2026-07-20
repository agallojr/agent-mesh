# agent-mesh

GitHub repository as a durable, outbound-only coordination bus for Claude
agents on machines that cannot reach each other directly.

Full protocol: [`spec/PROTOCOL.md`](spec/PROTOCOL.md)
Step-by-step node install: [`INSTALL.md`](INSTALL.md)

## Setup per machine

The quick version below; [`INSTALL.md`](INSTALL.md) has the full copy-paste
walkthrough (git gate, symlinks, identity, verification, troubleshooting).

1. Clone this repo; note its absolute path as `REPO_PATH`.
2. Copy `templates/agent-identity.env.template` to `~/.agent-identity.env`,
   fill in. Generate `AGENT_ID` once with `openssl rand -hex 3`; never change it.
3. Copy `templates/agent-credentials.env.template` to `~/.agent-credentials.env`,
   fill in, then `chmod 600`.
4. Install the git gate: copy `git-gate.py` to `~/.claude/hooks/`, register the
   `PreToolUse` Bash hook in `~/.claude/settings.json`, remove any blanket git
   deny, and add `REPO_PATH` to `~/.claude/mesh-git-allowlist.txt`. See
   [`guidance/permissions.md`](guidance/permissions.md).
5. Install the skills: symlink `skills/mesh-on` and `skills/mesh-off` into
   `~/.claude/skills/`.
6. Start Claude normally, then invoke `/mesh-on`. Stop later with `/mesh-off`.

Neither env file is ever committed. No machine name is hardcoded anywhere. The
guidance chain (best practices + how to operate as a mesh agent + permission
posture) ships in the repo, so every node -- hub or worker, real or test --
gets byte-identical instructions from one `git pull`, and the git gate lets the
agent sync the coordination repo without ever hanging on a permission prompt.
See [`guidance/`](guidance/).

## Layout

| Directory | Role |
|---|---|
| `spec/` | The protocol definition (`PROTOCOL.md`) — the normative reference. |
| `skills/` | The `mesh-on` / `mesh-off` Claude skills; symlinked into `~/.claude/skills/`. |
| `hooks/` | The `git-gate.py` PreToolUse hook, its settings snippet, and the allowlist template — the path-scoped-git mechanism. |
| `templates/` | `*.env.template` files copied to `$HOME` and filled in per node (never committed). |
| `guidance/` | The `CLAUDE.md` chain (best practices + operating + permissions) every node pulls verbatim. |
| `agents/` | Roster: one `<agent-id>.yaml` self-registration per node. |
| `tasks/` | Inboxes: `tasks/<agent-id>/` holds messages addressed to that node. |
| `status/` | Live task state, one `<task-id>.json` per task. |
| `outbox/` | Results and replies, `outbox/<agent-id>/` written by that node. |
| `mailbox/roles/librarian/` | Role-addressed lore submissions (any node writes). |
| `memory/lore/` | Hub-curated notes; hub is the sole writer. |
| `_archive/` | Cold storage; the hub sweeps terminal messages and status here. |

## Core invariants

- Single writer per path; merges are impossible by construction.
- Credentials referenced by name only; values never enter the repo.
- Messages are self-contained and immutable.
- Conflicts are re-derived, never resolved textually.
