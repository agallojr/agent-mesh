---
name: mm-off
description: Turn OFF persistent mm QA mode for this session. Removes the per-session flag so the UserPromptSubmit hook stops injecting the QA instruction; responses are no longer followed by a mini-me verdict.
allowed-tools: Bash
---

# mm-off — disable persistent mini-me QA mode

Turns off the per-session flag written by `/mm-on` by WRITING `off` into it
(not deleting it). On the next turn the `mm-qa-gate.py` hook reads the flag,
sees `off`, and no-ops, so responses stop carrying a QA verdict. Writing rather
than `rm`-ing means this never triggers a destructive-command confirmation.
One-shot `/mm` is unaffected — it can still be invoked on demand.

## Steps

1. Write `off` into the per-session flag (create the dir if missing):

   ```bash
   DIR="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/mm-active"
   mkdir -p "$DIR"
   printf 'off' > "$DIR/${CLAUDE_CODE_SESSION_ID}.flag"
   echo "mm QA mode OFF for session ${CLAUDE_CODE_SESSION_ID}"
   ```

2. Confirm to the user that mm QA mode is OFF for this session.
