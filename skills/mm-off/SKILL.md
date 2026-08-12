---
name: mm-off
description: Turn OFF persistent mm QA mode for this session. Removes the per-session flag so the UserPromptSubmit hook stops injecting the QA instruction; responses are no longer followed by a mini-me verdict.
allowed-tools: Bash
---

# mm-off — disable persistent mini-me QA mode

Removes the per-session flag written by `/mm-on`. On the next turn the
`mm-qa-gate.py` hook finds no flag and no-ops, so responses stop carrying a QA
verdict. One-shot `/mm` is unaffected — it can still be invoked on demand.

## Steps

1. Remove the per-session flag:

   ```bash
   DIR="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/mm-active"
   rm -f "$DIR/${CLAUDE_CODE_SESSION_ID}.flag"
   echo "mm QA mode OFF for session ${CLAUDE_CODE_SESSION_ID}"
   ```

2. Confirm to the user that mm QA mode is OFF for this session.
