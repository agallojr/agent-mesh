#!/usr/bin/env /usr/bin/python3
"""SessionStart hook: surface this machine's lore catalog at session start.

Every Claude session on a mesh node — interactive OR the /mesh-on poll loop —
should begin already aware of the operational lore that holds on THIS machine.
The failure this fixes: an agent cannot grep for lore it does not know exists.
The guidance says "consult the library before acting" (PROTOCOL §7, agent-
operating step 4a), but the CLAUDE.md @-import chain never loads memory/lore/,
so a fresh session has no signal that any relevant gotcha is on file. Agents
were repeatedly re-discovering things already recorded (e.g. where the q8020
GitHub issue tracker lives).

What it does: resolve this node's AGENT_CONTEXT from ~/.agent-identity.env, grep
memory/lore/*.md front-matter for records whose `contexts` include that context
(the coarse environment class, PROTOCOL §4/§7) OR are empty (universal — true
everywhere), and inject a compact CATALOG (id · title, plus tags) into the
session's initial context. It injects the catalog, not the full bodies: the
catalog is cheap (~tens of tokens per record) and its job is only to tell the
agent WHICH lore exists so it reads the pertinent ones by id (discovery stays a
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
# Lazy annotations so PEP 604 unions work under a pinned 3.9 /usr/bin/python3.
from __future__ import annotations

import glob
import json
import os
import re
import sys


def _identity() -> dict:
    """Parse ~/.agent-identity.env into a dict (values stripped of quotes and
    trailing # comments). Returns {} if the file is absent/unreadable."""
    out: dict = {}
    try:
        with open(os.path.expanduser("~/.agent-identity.env")) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                # strip an inline comment, then surrounding quotes/space
                val = val.split("#", 1)[0].strip().strip("'\"")
                out[key.strip()] = val
    except Exception:
        pass
    return out


def _fm_block(text: str) -> str:
    """Return the YAML front-matter block (between the first two --- fences)."""
    m = re.search(r"^---\s*$(.*?)^---\s*$", text, re.M | re.S)
    return m.group(1) if m else ""


def _field(block: str, name: str) -> str:
    m = re.search(rf"^{name}:\s*(.*)$", block, re.M)
    return m.group(1).strip() if m else ""


def _list_field(block: str, name: str) -> list:
    raw = _field(block, name)
    return [v.strip().strip("'\"") for v in raw.strip("[]").split(",") if v.strip()]


def _catalog(lore_dir: str, context: str) -> list:
    """Records whose contexts include `context` or are empty (universal).

    Returns a list of (why, id, title, tags) sorted by id. `why` is the matched
    context or 'universal'. A record with a non-empty contexts list that does
    not include our context is skipped (its fact is scoped elsewhere)."""
    rows = []
    for path in sorted(glob.glob(os.path.join(lore_dir, "*.md"))):
        try:
            block = _fm_block(open(path, encoding="utf-8").read())
        except Exception:
            continue
        ctxs = _list_field(block, "contexts")
        if not ctxs:
            why = "universal"
        elif context and context in ctxs:
            why = context
        else:
            continue
        rows.append(
            (why, _field(block, "id"), _field(block, "title"),
             ", ".join(_list_field(block, "tags")))
        )
    return rows


def main() -> int:
    try:
        raw = sys.stdin.read()
        _ = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0  # fail open

    ident = _identity()
    repo = ident.get("REPO_PATH", "")
    context = ident.get("AGENT_CONTEXT", "")
    if not repo:
        return 0  # no bus location — nothing to scan; fail open

    lore_dir = os.path.join(repo, "memory", "lore")
    if not os.path.isdir(lore_dir):
        return 0

    rows = _catalog(lore_dir, context)
    if not rows:
        return 0

    scope = context or "this machine"
    lines = [
        f"[mesh lore — {len(rows)} record(s) that hold on {scope} "
        f"(context={context or 'none'})]",
        "Operational lore on file for this machine. Consult the library before "
        "work with a known failure surface (PROTOCOL §7): when your task touches "
        "one of these subjects, READ the full record by id under "
        f"{lore_dir}/<id>-*.md before acting, and cite the id in your result. "
        "This catalog is a session-start convenience, not a substitute for the "
        "grep — new lore may have landed since.",
    ]
    for why, id_, title, tags in rows:
        tag_str = f"  ·  tags: {tags}" if tags else ""
        marker = "" if why == "universal" else f" [{why}]"
        lines.append(f"- {id_}{marker}: {title}{tag_str}")

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
