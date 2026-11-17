#!/usr/bin/env /usr/bin/python3
"""PreToolUse / PostToolUseFailure hook: show lore at the command it is about.

The session-start catalog (lore-recall.py) covers "what holds on this node".
This hook covers "what holds for this command": a lore record whose `triggers`
match a Bash command or a WebFetch URL is shown to the agent when that call is
made, once per session, and only where its `contexts` hold (PROTOCOL §7).

Modes, set per record by `trigger_mode` (default hint):
  hint   PreToolUse. Title, Fix and path are added to context. Claude Code
         delivers PreToolUse additionalContext with the tool result, so it
         informs the next call, not this one.
  fail   PostToolUseFailure only. Shown when a matching call fails, so it
         costs nothing when the call succeeds. For gotchas that fail loudly.
  block  PreToolUse. The first matching call is denied with the Fix as the
         reason; the same call issued again passes. For gotchas whose failure
         is silent or costly.

When a Bash call fails, matching records are shown, or named again if they
were already shown. If none match, one line points at the lore grep and asks
for a record with triggers once the fix is known. That line comes once per
command name per session, and never for commands whose non-zero exit is
routine (grep, diff, test, ...).

Trigger syntax: space-separated token patterns. The first must match the
command name (its basename); each later one must match a later token of the
same simple command, in order, with other tokens skipped. A pattern is an
fnmatch glob, and `a|b` is an alternation. Tokens match as written or with
`$VAR`, `${VAR}`, `~` and `$HOME` expanded from assignments made earlier in
the same call. A pattern `dir=<glob>`, anywhere in the trigger, must match the
directory the command runs in: the call's cwd, moved by any cd or pushd
before it, and for git the root of the repo that -C names. WebFetch is
matched as `WebFetch <url>`. Examples: `git commit`, `ssh genode`,
`git -C $*|~* add|commit|push`, `git dir=*/bus add -A`,
`WebFetch *osti.gov*`.

State: the ids shown, per session and agent, in ~/.cache/mesh-lore-trigger/.
Debug: if that folder holds a file named `debug`, each payload is appended to
debug.log there. Posture: fail open; any error exits 0 with no output.
Python 3.6-safe.
"""
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
import time
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import lore_fm  # noqa: E402

STATE_DIR = os.path.expanduser("~/.cache/mesh-lore-trigger")
SEPARATORS = {";", ";;", "&", "&&", "|", "||", "|&", "(", ")", "\n"}
WRAPPERS = {"env", "command", "exec", "nohup", "time", "builtin", "nice"}
SHELLS = {"bash", "sh", "zsh", "dash"}
DECLARE = {"export", "local", "declare", "readonly", "typeset"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
GIT_VALUE_OPTS = {"-c", "--work-tree", "--namespace", "--exec-path",
                  "--super-prefix", "--config-env"}
# Commands whose non-zero exit is routine; no "file lore" nudge for these.
ROUTINE = {
    "grep", "egrep", "fgrep", "rg", "diff", "cmp", "test", "[", "[[", "find",
    "ls", "cat", "head", "tail", "which", "type", "pgrep", "true", "false",
    "wc", "sort", "uniq", "cut", "awk", "sed", "echo", "printf", "read",
    "stat", "file", "jq", "kill", "pkill", "wait", "sleep", "exit", "cd",
}
# Section headings (regexes) taken as a record's fix, in order of preference.
FIX_HEADINGS = (r"Fix\b[^\n]*", r"What works\b[^\n]*",
                r"How to work around\b[^\n]*", r"Workaround\b[^\n]*")
FIX_CHARS = 900
TOTAL_CHARS = 3200


Cmd = Dict[str, object]  # {"raw": [...], "exp": [...], "dir": str}


def simple_commands(command: str, cwd: str = "") -> List[Cmd]:
    """Split a shell command into simple commands. Each has its tokens as
    written (`raw`), the same tokens with variables assigned earlier in the
    call, `~` and `$HOME` expanded (`exp`), and the directory it runs in
    (`dir`): cwd, moved by any cd or pushd before it, and for git the root of
    the repo its -C points at. The first token is the command name (its
    basename); assignments, wrappers and `bash -c` are unwrapped. Quotes are
    honoured. `dir` is '' where it cannot be known."""
    env = {"HOME": os.path.expanduser("~")}
    out = []  # type: List[Cmd]
    _walk(command, env, {"dir": cwd}, out)
    return out


def _tokens(command: str) -> List[str]:
    command = re.sub(r"\d*>&\d+|&>", " ", command)
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        tokens = re.split(r"\s+|(;|&&|\|\||\||&|\n)", command)
        return [t for t in tokens if t]


def _walk(command: str, env: Dict[str, str], state: Dict[str, str],
          out: List[Cmd]) -> None:
    cur = []  # type: List[str]
    for tok in _tokens(command) + [";"]:
        if tok in SEPARATORS:
            if cur:
                _one(cur, env, state, out)
            cur = []
        else:
            cur.append(tok)


def _expand(tok: str, env: Dict[str, str]) -> str:
    def sub(m):
        return env.get(m.group(1) or m.group(2), m.group(0))
    out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)",
                 sub, tok)
    if out == "~" or out.startswith("~/"):
        out = env["HOME"] + out[1:]
    return out


def _assign(raw: str, exp: str, env: Dict[str, str]) -> None:
    if ASSIGN.match(raw):
        name, val = exp.split("=", 1)
        env[name] = val


def _join(base: str, path: str) -> str:
    if not path or "$" in path or "`" in path:
        return ""
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.join(base, path)) if base else ""


def _one(raw: List[str], env: Dict[str, str], state: Dict[str, str],
         out: List[Cmd]) -> None:
    exp = [_expand(t, env) for t in raw]
    i = 0
    while i < len(raw) and (ASSIGN.match(raw[i]) or raw[i] in WRAPPERS):
        _assign(raw[i], exp[i], env)
        i += 1
    if i < len(raw) and raw[i] == "timeout":
        i += 1
        while i < len(raw) and raw[i].startswith("-"):
            i += 1
        i += 1  # its duration
    raw, exp = raw[i:], exp[i:]
    if not raw:
        return
    name = os.path.basename(raw[0]) or raw[0]
    if name in SHELLS and len(raw) > 2 and raw[1] == "-c":
        _walk(raw[2], env, state, out)
        return
    here = state["dir"]
    if name in DECLARE:
        for r, e in zip(raw[1:], exp[1:]):
            _assign(r, e, env)
    elif name in ("cd", "pushd"):
        args = [e for e in exp[1:] if not e.startswith("-")]
        state["dir"] = _join(here, args[0]) if args else env["HOME"]
    elif name == "popd":
        state["dir"] = ""
    elif name == "git":
        here = _git_dir(raw, exp, here)
    out.append({"raw": [name] + raw[1:], "exp": [name] + exp[1:],
                "dir": here})


def _git_dir(raw: List[str], exp: List[str], base: str) -> str:
    """The root of the repo a git command acts on: base moved by each -C
    or --git-dir, then resolved with rev-parse. '' if it cannot be known."""
    d = base
    i = 1
    while i < len(raw):
        t = raw[i]
        if t == "-C" and i + 1 < len(raw):
            d = _join(d, exp[i + 1])
            i += 2
        elif t.startswith("--git-dir"):
            if t == "--git-dir" and i + 1 < len(raw):
                gd, i = exp[i + 1], i + 2
            else:
                gd, i = exp[i].split("=", 1)[-1], i + 1
            d = re.sub(r"/\.git/?$", "", _join(d, gd))
        elif t in GIT_VALUE_OPTS:
            i += 2
        elif t.startswith("-"):
            i += 1
        else:
            break
    if not d or not os.path.isdir(d):
        return d
    try:
        p = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=2)
        top = p.stdout.strip()
        return top if p.returncode == 0 and top else d
    except Exception:
        return d


def tok_match(pattern: str, token: str) -> bool:
    return any(fnmatch.fnmatchcase(token, alt) for alt in pattern.split("|"))


def _in_order(pats: List[str], toks: List[str]) -> bool:
    if not pats or not toks or not tok_match(pats[0], toks[0]):
        return False
    i = 1
    for pat in pats[1:]:
        while i < len(toks) and not tok_match(pat, toks[i]):
            i += 1
        if i >= len(toks):
            return False
        i += 1
    return True


def trigger_matches(trigger: str, cmd: Cmd) -> bool:
    """Token patterns match in order against the raw or the expanded
    tokens; each `dir=<glob>` must match the command's directory."""
    pats = trigger.split()
    dirs = [p[4:] for p in pats if p.startswith("dir=")]
    toks = [p for p in pats if not p.startswith("dir=")]
    if dirs and not (cmd["dir"] and all(tok_match(p, cmd["dir"])
                                        for p in dirs)):
        return False
    return _in_order(toks, cmd["raw"]) or (
        cmd["exp"] != cmd["raw"] and _in_order(toks, cmd["exp"]))


def commands_of(payload: Dict) -> List[Cmd]:
    tool = payload.get("tool_name", "")
    tin = payload.get("tool_input") or {}
    if tool == "Bash":
        return simple_commands(tin.get("command", "") or "",
                               payload.get("cwd", "") or "")
    if tool == "WebFetch":
        url = tin.get("url", "") or ""
        return [{"raw": ["WebFetch", url], "exp": ["WebFetch", url],
                 "dir": ""}]
    return []


def matching(recs: List[Dict], cmds: List[Cmd],
             context: str) -> List[Tuple[Dict, str]]:
    """(record, trigger) for each record that holds here and has a trigger
    matching any of the simple commands."""
    hits = []
    for rec in recs:
        if not rec["triggers"] or not lore_fm.holds(rec["contexts"], context):
            continue
        for trig in rec["triggers"]:
            if any(trigger_matches(trig, c) for c in cmds):
                hits.append((rec, trig))
                break
    return hits


def fix_text(rec: Dict) -> str:
    """The record's fix: the first section whose heading reads as one, else
    the start of the body."""
    text = ""
    for heading in FIX_HEADINGS:
        text = lore_fm.section(rec["text"], heading)
        if text:
            break
    text = text or lore_fm.body(rec["text"])
    text = re.sub(r"\n{3,}", "\n\n", text)
    if len(text) > FIX_CHARS:
        text = text[:FIX_CHARS].rsplit(" ", 1)[0] + " [...]"
    return text


def render(hits: List[Tuple[Dict, str]], lead: str) -> str:
    parts = [lead]
    for rec, trig in hits:
        parts.append("- %s (trigger `%s`): %s\n  Fix, from the record:\n%s\n"
                     "  Full record: %s" % (
                         rec["id"], trig, rec["title"],
                         "\n".join("    " + ln for ln in
                                   fix_text(rec).splitlines()),
                         rec["path"]))
    parts.append("Read the full record if the fix above is not enough, and "
                 "cite its id in your result.")
    out = "\n".join(parts)
    return out[:TOTAL_CHARS]


def state_path(payload: Dict) -> str:
    sid = re.sub(r"[^A-Za-z0-9_.-]", "_", str(payload.get("session_id", "")))
    aid = re.sub(r"[^A-Za-z0-9_.-]", "_", str(payload.get("agent_id") or
                                               "main"))
    return os.path.join(STATE_DIR, "%s__%s.json" % (sid or "nosession", aid))


def load_state(path: str) -> Dict:
    try:
        with open(path) as fh:
            st = json.load(fh)
        return {"shown": list(st.get("shown", [])),
                "nudged": list(st.get("nudged", []))}
    except Exception:
        return {"shown": [], "nudged": []}


def save_state(path: str, st: Dict) -> None:
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, path)
        names = os.listdir(STATE_DIR)
        if len(names) > 200:
            cutoff = time.time() - 7 * 86400
            for n in names:
                p = os.path.join(STATE_DIR, n)
                if n.endswith(".json") and os.path.getmtime(p) < cutoff:
                    os.remove(p)
    except Exception:
        pass


def emit(event: str, **fields) -> None:
    out = {"hookEventName": event}
    out.update(fields)
    sys.stdout.write(json.dumps({"hookSpecificOutput": out}))


def pre_tool_use(payload: Dict, hits: List[Tuple[Dict, str]],
                 st: Dict) -> None:
    fresh = [(r, t) for r, t in hits
             if r["id"] not in st["shown"] and r["trigger_mode"] != "fail"]
    if not fresh:
        return
    st["shown"].extend(r["id"] for r, _ in fresh)
    blocks = [h for h in fresh if h[0]["trigger_mode"] == "block"]
    if blocks:
        reason = render(fresh, "[mesh lore] Held once: this call matches "
                        "lore whose failure is silent or costly. Apply the "
                        "fix, then issue the corrected call; this record "
                        "will not hold a call again this session.")
        emit("PreToolUse", permissionDecision="deny",
             permissionDecisionReason=reason)
        return
    emit("PreToolUse", additionalContext=render(
        fresh, "[mesh lore] The call you just made matches lore on file. "
        "Check its result against this before your next call:"))


def post_tool_failure(payload: Dict, hits: List[Tuple[Dict, str]],
                      cmds: List[Cmd], st: Dict, ldir: str) -> None:
    if payload.get("is_interrupt"):
        return
    fresh = [(r, t) for r, t in hits if r["id"] not in st["shown"]]
    seen = [(r, t) for r, t in hits if r["id"] in st["shown"]]
    msg = []
    if fresh:
        st["shown"].extend(r["id"] for r, _ in fresh)
        msg.append(render(fresh, "[mesh lore] That call failed, and it "
                          "matches lore on file. Read this before retrying:"))
    if seen:
        msg.append("[mesh lore] That call failed. Lore shown earlier this "
                   "session covers it; re-read before retrying: " + "; ".join(
                       "%s (%s)" % (r["id"], r["path"]) for r, _ in seen))
    if not hits:
        names = []
        for c in cmds:
            n = c["raw"][0]
            if n not in ROUTINE and n not in names:
                names.append(n)
        names = [n for n in names if n not in st["nudged"]][:3]
        if names:
            st["nudged"].extend(names)
            pat = " ".join("-e %s" % shlex.quote(n) for n in names)
            msg.append(
                "[mesh lore] That call failed and no lore trigger matches it "
                "(%s). Before you try another variant, check the library: "
                "grep -ilw %s %s/*.md. If you get it working only after "
                "more than one attempt, file the fix as lore with `triggers` "
                "(PROTOCOL §7)." % (", ".join(names), pat, ldir))
    if msg:
        emit("PostToolUseFailure", additionalContext="\n".join(msg))


def main() -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0
    try:
        if os.path.exists(os.path.join(STATE_DIR, "debug")):
            with open(os.path.join(STATE_DIR, "debug.log"), "a") as fh:
                fh.write(raw.strip() + "\n")
        event = payload.get("hook_event_name", "")
        if event not in ("PreToolUse", "PostToolUseFailure"):
            return 0
        ident = lore_fm.identity()
        ldir = lore_fm.lore_dir(ident.get("REPO_PATH", ""))
        if not ldir:
            return 0
        cmds = commands_of(payload)
        if not cmds:
            return 0
        hits = matching(lore_fm.records(ldir), cmds,
                        ident.get("AGENT_CONTEXT", ""))
        path = state_path(payload)
        st = load_state(path)
        before = json.dumps(st)
        if event == "PreToolUse":
            pre_tool_use(payload, hits, st)
        elif payload.get("tool_name") == "Bash" or hits:
            post_tool_failure(payload, hits, cmds, st, ldir)
        if json.dumps(st) != before:
            save_state(path, st)
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
