#!/usr/bin/env /usr/bin/python3
"""SessionStart hook: surface this machine's lore catalog at session start.

Every Claude session on a mesh node — interactive OR the /mesh-on poll loop —
should begin already aware of the operational lore that holds on THIS machine.
The failure this fixes: an agent cannot grep for lore it does not know exists.
The guidance says "consult the library before acting" (PROTOCOL §7, agent-
operating step 4a), but the CLAUDE.md @-import chain never loads the lore folder,
so a fresh session has no signal that any relevant gotcha is on file. Agents
were repeatedly re-discovering things already recorded (e.g. where the q8020
GitHub issue tracker lives).

What it does: resolve this node's AGENT_CONTEXT from ~/.agent-identity.env, grep
spaces/lore/lore/*.md (memory/lore/ if absent) front-matter for records whose
`contexts` include that context
(the coarse environment class, PROTOCOL §4/§7) OR are empty (universal — true
everywhere), and inject a compact CATALOG (id · title, plus tags) into the
session's initial context. Records that carry `triggers` are left out and
counted in one line: lore-trigger.py shows each at the command it is about,
which keeps this catalog small as lore grows. Front-matter parsing is shared
with that hook (lore_fm.py) and is Python 3.6-safe.

It injects the catalog, not the full bodies: the catalog is cheap (~tens of
tokens per record) and its job is only to tell the agent WHICH lore exists so it reads the pertinent ones by id (discovery stays a
grep over front-matter — there is no committed index, PROTOCOL §7). This mirrors
the "generate a view on demand, never commit an index" rule: the catalog is
built fresh each session start and never written to disk.

Why a SessionStart hook: loading is a per-session, harness-driven concern, not
something the model can bootstrap for itself (it cannot read a file it has not
been told about). SessionStart fires on new/resume/clear/compact; stdout with
exit 0 is added to the session's context via hookSpecificOutput.additionalContext
(same vehicle as UserPromptSubmit). It fires UNCONDITIONALLY here (no matcher) so
the catalog is also re-surfaced after a compaction, and so the hook never depends
on the exact `source`/lifecycle field name.

Contract (Claude Code SessionStart):
  stdin  : JSON with at least {"session_id": ..., "hook_event_name": ...}. Unused
           here beyond fail-open parsing — the catalog is the same regardless.
  stdout : on exit 0, hookSpecificOutput.additionalContext is added to context.

Posture: FAIL OPEN. Any error (no identity, unreadable bus, no lore dir) exits 0
with no output — a broken recall hook must never block or delay a session.
"""
import json
import os
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import lore_fm  # noqa: E402


def _catalog(recs: List[Dict], context: str) -> List[Dict]:
    """Records that hold here (contexts empty or naming this context) and
    carry no triggers. A triggered record is shown by lore-trigger.py at the
    command it is about, so it stays out of the session-start catalog."""
    return [r for r in recs
            if lore_fm.holds(r["contexts"], context) and not r["triggers"]]


def main() -> int:
    try:
        raw = sys.stdin.read()
        _ = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0  # fail open
    try:
        ident = lore_fm.identity()
        context = ident.get("AGENT_CONTEXT", "")
        ldir = lore_fm.lore_dir(ident.get("REPO_PATH", ""))
        if not ldir:
            return 0
        recs = lore_fm.records(ldir)
        rows = _catalog(recs, context)
        triggered = [r for r in recs if r["triggers"]
                     and lore_fm.holds(r["contexts"], context)]
    except Exception:
        return 0
    if not rows and not triggered:
        return 0

    scope = context or "this machine"
    lines = [
        "[mesh lore — %d record(s) that hold on %s (context=%s)]"
        % (len(rows), scope, context or "none"),
        "Operational lore on file for this machine. Consult the library before "
        "work with a known failure surface (PROTOCOL §7): when your task touches "
        "one of these subjects, READ the full record by id under "
        "%s/<id>-*.md before acting, and cite the id in your result. "
        "This catalog is a session-start convenience, not a substitute for the "
        "grep — new lore may have landed since." % ldir,
    ]
    for r in rows:
        tags = ", ".join(r["tags"])
        tag_str = "  ·  tags: %s" % tags if tags else ""
        marker = " [%s]" % context if r["contexts"] else ""
        lines.append("- %s%s: %s%s" % (r["id"], marker, r["title"], tag_str))
    if triggered:
        lines.append(
            "%d more record(s) that hold here carry command triggers; the "
            "lore-trigger hook shows each one when a matching command runs. "
            "When it does, act on it." % len(triggered))

    out = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "\n".join(lines),
        }
    }
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
