#!/usr/bin/env /usr/bin/python3
"""UserPromptSubmit hook: persistent mm QA mode.

When mm QA mode is ON for the current session, this hook injects a standing
instruction on every user turn telling the primary agent to spawn the mini-me
QA sub-agent (synchronously) after composing its response and append the
verdict. When the mode is OFF, the hook is a silent no-op.

Why a hook: a Skill invocation only affects the turn it runs in. Making EVERY
subsequent response carry a QA verdict is a cross-turn behavior, which the
harness — not the model — must drive. UserPromptSubmit fires before each turn
and its stdout is added to the model's context (Claude Code docs), so it is the
vehicle for re-injecting the instruction each turn.

State model: mm-on / mm-off skills toggle a per-session flag file
    <config_dir>/mm-active/<session_id>.flag
keyed by the session id. This hook checks for that file's existence for the
current session_id (provided on stdin) and injects only when present, so the
mode is scoped per session, not global.

A command hook cannot itself call tools / spawn an agent (docs). It only emits
context. The actual QA spawn is performed by the primary agent, following the
instruction injected here (and the canonical protocol in the mm skill).

Contract (Claude Code UserPromptSubmit):
  stdin  : JSON with at least {"session_id": "...", "hook_event_name": ...}.
  stdout : on exit 0, emitted text/JSON is added to the model's context.
           hookSpecificOutput.additionalContext is the explicit injection field.

Posture: FAIL OPEN. Any error (bad JSON, missing session id, unreadable dir)
exits 0 with no output — a broken QA gate must never block the user's prompt.
"""
# Lazy annotations so PEP 604 unions work under a pinned 3.9 /usr/bin/python3.
from __future__ import annotations

import json
import os
import sys


def _config_dir() -> str:
    """Resolve the Claude Code config dir, matching git-gate.py."""
    for var in ("CLAUDE_CODE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"):
        val = os.environ.get(var)
        if val:
            return os.path.expanduser(val)
    return os.path.expanduser("~/.claude")


def _flag_path(session_id: str) -> str:
    return os.path.join(_config_dir(), "mm-active", f"{session_id}.flag")


# The standing instruction injected each turn while the mode is active. Kept
# self-contained (the mm skill is not in context during a persistent-mode
# turn), but the mm skill at bus/product/skills/mm/SKILL.md remains canonical.
_INSTRUCTION = (
    "[mm QA mode ACTIVE — you are being watched, no bullshit]\n"
    "After you finish composing your response to the user THIS turn, before the "
    "turn ends, run a mini-me QA check on it:\n"
    "1. Spawn ONE sub-agent via the Agent tool, run_in_background:false "
    "(synchronous), subagent_type:'general-purpose' (NOT Explore/Plan — those "
    "skip CLAUDE.md). Set model one tier below yours, floored at Sonnet: "
    "Fable->opus, Opus->sonnet, Sonnet->sonnet.\n"
    "2. Give it the user's request and your response VERBATIM, and this task: "
    "reload guidance by reading in full "
    "research-notes/bus/product/guidance/best-practices.base.md and "
    "research-notes/bus/memory/best-practices.user.md, then judge whether the "
    "response satisfies the request on TWO axes, adversarially on both. "
    "FORM (grounding): claims asserted as fact but not verified against "
    "code/data/a cited source, overreach beyond the ask, guidance violations. "
    "CONTENT (merits): is it actually correct, is the reasoning sound, does it "
    "address the real intent and not just the literal words, is anything "
    "missing/misleading, and is the approach right or is there an obviously "
    "better one — a claim can be faithfully sourced and still wrong, "
    "incomplete, or beside the point, and that must not pass. Stay scoped to "
    "the request; do not invent new requirements. It may read files / grep to "
    "check claims. Return "
    "exactly two lines: line1 = a colored verdict, one of `\U0001F7E2 GREEN` / "
    "`\U0001F7E1 YELLOW` / `\U0001F534 RED` (leading circle glyph included); "
    "line2 = one terse reason (<=25 words).\n"
    "3. Append the verdict as the final line of your turn, verbatim and "
    "color-flagged with its leading circle glyph: "
    "`mini-me (<model>): \U0001F7E2 GREEN | \U0001F7E1 YELLOW | \U0001F534 RED "
    "— <reason>`. Do not skip it. Do not soften a YELLOW/RED into a pass.\n"
    "(mm QA mode persists until /mm-off. Full protocol: mm skill.)"
)


def main() -> int:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0  # fail open

    session_id = data.get("session_id") or os.environ.get(
        "CLAUDE_CODE_SESSION_ID", ""
    )
    if not session_id:
        return 0

    try:
        active = os.path.isfile(_flag_path(session_id))
    except Exception:
        return 0

    if not active:
        return 0

    out = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": _INSTRUCTION,
        }
    }
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
