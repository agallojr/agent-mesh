# hooks/ — the git gate and the lore hooks

The mesh agent runs `git add/commit/push` itself every cycle. Claude Code's
`deny` beats `allow` at every scope and its permission rules are not path-aware,
so "allow git only in the coordination repo" cannot be a permission rule. This
hook is the resolution: it is registered as the node's sole `PreToolUse` gate on
`Bash` git, permitting the three mutating ops only for allowlisted repos.

These files are **canonical here in the repo** so they travel to every node, but
the **active copies live in `~/.claude`** (harness config lives centrally, never
vendored per-repo). Install per node:

1. Copy `git-gate.py` to `~/.claude/hooks/git-gate.py` (`chmod +x`).
2. Merge `settings.snippet.json` into `~/.claude/settings.json`: register the
   `PreToolUse` Bash hook (replace `REPLACE_WITH_HOME` with the real `$HOME`),
   and remove any blanket `git add/commit/push` deny (keep `sudo` denied).
3. Copy `mesh-git-allowlist.txt.template` to `~/.claude/mesh-git-allowlist.txt`
   and add this node's coordination-repo clone path (its `REPO_PATH`).

## Contract

- Permits `git add/commit/push` only when the target repo is on the allowlist.
- Read-only git (`pull`, `fetch`, `status`, `log`) is never gated.
- Non-git commands are never touched.
- **Fail-closed:** if the target cannot be proven allowlisted, it is denied.
  This includes `git -C "$VAR"` (unexpanded variable), `cd repo && git push`
  (cwd not trustable), `$(...)`/backtick/`~`/glob in the path, and `--git-dir`
  to a non-allowlisted repo. Agents MUST emit `git -C /literal/abs/path <op>`.

The interpreter is pinned to `/usr/bin/python3` (the shebang) so it does not pick
up a project virtualenv from `PATH`.

## Lore hooks

Two hooks bring the lore library (PROTOCOL §7) to the agent at the moment it is
needed, so a node does not repeat a mistake that is already on file. Both run
in place from the bus checkout (no copy into `~/.claude`), share the front-matter
parser `lore_fm.py`, are Python 3.6-safe and fail open.

- `lore-recall.py` (SessionStart): lists the lore that holds on this node's
  `AGENT_CONTEXT`. Records that carry `triggers` are only counted.
- `lore-trigger.py` (PreToolUse and PostToolUseFailure, on `Bash|WebFetch`):
  shows a record whose `triggers` match the call, once per session and agent,
  according to its `trigger_mode` (`hint`, `fail` or `block`). When a Bash call
  fails and no record matches it, the hook adds one line asking the agent to grep
  the lore and to file the fix with triggers. State is kept in
  `~/.cache/mesh-lore-trigger/`; touch `debug` there to log each payload to
  `debug.log`.

To install, merge the `SessionStart`, second `PreToolUse` and `PostToolUseFailure`
entries of `settings.snippet.json` into `~/.claude/settings.json`, with
`REPLACE_WITH_REPO_PATH` set to the bus checkout (`REPO_PATH`). Claude Code adds
PreToolUse context to the tool result, so a `hint` informs the agent's next call,
not the current one. The context still arrives when the git gate denies the same
call, which is the moment it is most useful.
