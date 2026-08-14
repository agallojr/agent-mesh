---
name: mm-on
description: Turn ON persistent mm QA mode for this session. From now until /mm-off, every assistant response is followed by a synchronous mini-me QA verdict (green/yellow/red + terse reason). Writes a per-session flag the UserPromptSubmit hook reads each turn. Also reloads the guidance stack.
allowed-tools: Read, Bash, Glob, Grep
---

# mm-on — enable persistent mini-me QA mode

Turns on continuous QA: after every response this session, a same-or-one-lower-
tier mini-me sub-agent grades the response against the user's request and its
verdict is appended to the turn. Stays on until `/mm-off`.

## Mechanism (why a flag + hook, not just this skill)

A skill only affects the turn it runs in. Persistent per-turn behavior is driven
by the `mm-qa-gate.py` UserPromptSubmit hook, which — when a per-session flag
exists — re-injects the QA instruction every turn. This skill's job is to create
that flag; the hook and the mm skill hold the actual protocol.

## Steps

1. Reload the guidance stack (read in full, treat as binding). Resolve the bus
   root as `REPO_PATH` from `~/.agent-identity.env` (fall back to the bus clone
   this session is working in):
   - `<REPO_PATH>/product/guidance/best-practices.base.md`
   - `<REPO_PATH>/memory/best-practices.user.md` (may be absent — skip if so)

2. Write the per-session flag keyed by the session id. The session id is in the
   `CLAUDE_CODE_SESSION_ID` env var (verified present to the Bash tool):

   ```bash
   DIR="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/mm-active"
   mkdir -p "$DIR"
   printf 'on' > "$DIR/${CLAUDE_CODE_SESSION_ID}.flag"
   echo "mm QA mode ON for session ${CLAUDE_CODE_SESSION_ID}"
   ```

   (Content-based state: the hook treats the flag as ACTIVE unless its content
   is `off`. `/mm-off` writes `off` rather than deleting the file, so neither
   toggle runs a destructive `rm`.)

3. Confirm to the user that mm QA mode is ON and note the cost: every response
   now triggers a synchronous sub-agent spawn — real added latency and tokens
   per turn — until `/mm-off`.

## Prerequisite (one-time, per machine)

The hook must be registered in `~/.claude/settings.json` under
`hooks.UserPromptSubmit` pointing at the bus's copy of
`product/hooks/mm-qa-gate.py`. If continuous verdicts do not
appear after enabling, the hook is not installed — say so; do not pretend the
mode is working. Installing/editing settings.json is a config change: use the
update-config path, do not silently assume it is present.
