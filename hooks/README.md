# hooks/ — the git gate

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
